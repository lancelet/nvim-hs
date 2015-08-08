{-# LANGUAGE LambdaCase #-}
{- |
Module      :  Neovim.Main
Description :  Wrapper for the actual main function
Copyright   :  (c) Sebastian Witte
License     :  Apache-2.0

Maintainer  :  woozletoff@gmail.com
Stability   :  experimental

-}
module Neovim.Main
    where

import           Neovim.Config
import qualified Neovim.Context.Internal    as Internal
import           Neovim.Debug
import           Neovim.Plugin              as P
import qualified Neovim.Plugin.ConfigHelper as ConfigHelper
import           Neovim.Plugin.Internal     (getAllFunctionNames)
import           Neovim.RPC.Common          as RPC
import           Neovim.RPC.EventHandler
import           Neovim.RPC.SocketReader

import qualified Config.Dyre                as Dyre
import qualified Config.Dyre.Relaunch       as Dyre
import           Control.Concurrent
import           Control.Monad
import           Data.Monoid
import qualified Data.Set                   as Set
import           Options.Applicative
import           System.IO                  (stdin, stdout)
import           System.SetEnv

import           System.Environment
import           Prelude

data CommandLineOptions =
    Opt { providerName :: String
        , hostPort     :: Maybe (String, Int)
        , unix         :: Maybe FilePath
        , env          :: Bool
        , logOpts      :: Maybe (FilePath, Priority)
        }


optParser :: Parser CommandLineOptions
optParser = Opt
    <$> strArgument
        (metavar "NAME"
        <> help "Name that associates the plugin provider with neovim")
    <*> optional ((,)
            <$> strOption
                (long "host"
                <> short 'a'
                <> metavar "HOSTNAME"
                <> help "Connect to the specified host. (requires -p)")
            <*> option auto
                (long "port"
                <> short 'p'
                <> metavar "PORT"
                <> help "Connect to the specified port. (requires -a)"))
    <*> optional (strOption
        (long "unix"
        <> short 'u'
        <> help "Connect to the given unix domain socket."))
    <*> switch
        ( long "environment"
        <> short 'e'
        <> help "Read connection information from $NVIM_LISTEN_ADDRESS.")
    <*> optional ((,)
        <$> strOption
            (long "log-file"
            <> short 'l'
            <> help "File to log to.")
        <*> option auto
            (long "log-level"
            <> short 'v'
            <> help ("Log level. Must be one of: " ++ (unwords . map show) logLevels)))
  where
    -- [minBound..maxBound] would have been nice here.
    logLevels :: [Priority]
    logLevels = [ DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT, EMERGENCY ]


opts :: ParserInfo CommandLineOptions
opts = info (helper <*> optParser)
    (fullDesc
    <> header "Start a neovim plugin provider for Haskell plugins."
    <> progDesc "This is still work in progress. Feel free to contribute.")


-- | This is essentially the main function for /nvim-hs/, at least if you want
-- to use the "Config.Dyre" for the configuration..
neovim :: NeovimConfig -> IO ()
neovim conf =
    let params = Dyre.defaultParams
            { Dyre.showError   = \cfg errM -> cfg { errorMessage = Just errM }
            , Dyre.projectName = "nvim"
            , Dyre.realMain    = realMain
            , Dyre.statusOut   = debugM "Dyre"
            , Dyre.ghcOpts     = ["-threaded", "-rtsopts", "-with-rtsopts=-N"]
            }
    in Dyre.wrapMain params (conf { dyreParams = Just params })


realMain :: NeovimConfig -> IO ()
realMain cfg = do
    os <- execParser opts
    maybe disableLogger (uncurry withLogger) (logOpts os <|> logOptions cfg) $ do
        logM "Neovim.Main" DEBUG "Starting up neovim haskell plguin provider"
        runPluginProvider os cfg


runPluginProvider :: CommandLineOptions -> NeovimConfig -> IO ()
runPluginProvider os = case (hostPort os, unix os) of
    (Just (h,p), _) -> let s = TCP p h in run s s
    (_, Just fp)    -> let s = UnixSocket fp in run s s
    _ | env os      -> run Environment Environment
    _               -> run (Stdout stdout) (Stdout stdin)

  where
    run evHandlerSocket sockreaderSocket cfg = do
        ghcEnv <- forM ["GHC_PACKAGE_PATH","CABAL_SANDBOX_CONFIG"] $ \var -> do
            val <- lookupEnv var
            unsetEnv var
            return (var, val)

        rpcConfig <- newRPCConfig
        conf <- Internal.newConfig (pure (providerName os)) (pure ())

        let allPlugins = maybe id ((:) . ConfigHelper.plugin ghcEnv) (dyreParams cfg) $
                            plugins cfg
            startupConf = conf { Internal.customConfig = ()
                               , Internal.pluginSettings = Nothing
                               }
        startPluginThreads startupConf allPlugins >>= \case
            Left e -> errorM "Neovim.Main" $ "Error initializing plugins: " <> e
            Right pluginsAndTids -> do
                let allFunctions = Set.fromList $
                        concatMap (getAllFunctionNames . fst) pluginsAndTids
                let rpcEnv = conf { Internal.customConfig = rpcConfig
                                  , Internal.pluginSettings = Nothing
                                  }
                ehTid <- forkIO $ runEventHandler evHandlerSocket rpcEnv
                let registerConf = conf
                        { Internal.customConfig = ()
                        , Internal.pluginSettings = Nothing
                        }
                _ <- forkIO $ register registerConf (map fst pluginsAndTids)
                rTid <- forkIO $ runSocketReader sockreaderSocket rpcEnv allFunctions
                debugM "Neovim.Main" "Waiting for threads to finish."
                let pluginTids = concatMap snd pluginsAndTids
                finish (rTid:ehTid:pluginTids) =<< readMVar (Internal.quit conf)


finish :: [ThreadId] -> Internal.QuitAction -> IO ()
finish threads = \case
    Internal.Restart -> do
        debugM "Neovim.Main" "Trying to restart nvim-hs"
        mapM_ killThread threads
        Dyre.relaunchMaster Nothing
    Internal.Quit -> return ()

