{-# OPTIONS_GHC -fno-warn-orphans #-}
module Application
    ( getApplicationDev
    , appMain
    , develMain
    , makeFoundation
    -- * for DevelMain
    , getApplicationRepl
    , shutdownApp
    -- * for GHCI
    , handler
    ) where

import Control.Monad.Logger                 (liftLoc)
import qualified Database.EventStore as E
import Import
import Language.Haskell.TH.Syntax           (qLocation)
import Network.Wai.Handler.Warp             (Settings, defaultSettings,
                                             defaultShouldDisplayException,
                                             runSettings, setHost,
                                             setOnException, setPort, getPort)
import Network.Wai.Middleware.RequestLogger (Destination (Logger),
                                             IPAddrSource (..),
                                             OutputFormat (..), destination,
                                             mkRequestLogger, outputFormat)
import System.Log.FastLogger                (defaultBufSize, newFileLoggerSet,
                                             toLogStr, pushLogStrLn, flushLogStr)

import qualified Aggregate.Authors as Authors
import qualified Aggregate.Posts as Posts
import qualified Aggregate.Stats as Stats

-- Import all relevant handler modules here.
-- Don't forget to add new modules to your cabal file!
import Handler.Admin
import Handler.Common
import Handler.Home
import Handler.Post

-- This line actually creates our YesodDispatch instance. It is the second half
-- of the call to mkYesodData which occurs in Foundation.hs. Please see the
-- comments there for more details.
mkYesodDispatch "App" resourcesApp

initLog logger str = pushLogStrLn (loggerSet logger) str

flushInitLog logger = flushLogStr (loggerSet logger)

-- | This function allocates resources (such as a database connection pool),
-- performs initialization and return a foundation datatype value. This is also
-- the place to put your migrate statements to have automatic database
-- migrations handled by Yesod.
makeFoundation :: AppSettings -> IO App
makeFoundation appSettings = do
    -- Some basic initializations: HTTP connection manager, logger, and static
    -- subsite.
    appHttpManager <- newManager
    appLogger <- newFileLoggerSet defaultBufSize "web.log" >>= makeYesodLogger
    appStatic <-
        (if appMutableStatic appSettings then staticDevel else static)
        (appStaticDir appSettings)

    let conf  = appStoreConf appSettings
        cred  = E.credentials (storeLogin conf) (storePassword conf)
        setts = E.defaultSettings
                { E.s_credentials = Just cred
                , E.s_retry       = E.keepRetrying
                }
    conn       <- E.connect setts (storeIp conf) (storePort conf)
    initLog appLogger "Initiated EventStore connection"
    initLog appLogger "Start building Posts aggregate…"
    appPosts   <- Posts.buildPosts conn
    initLog appLogger "Posts aggregate built"
    initLog appLogger "Start building Authors aggregate…"
    appAuthors <- Authors.buildAuthors conn
    initLog appLogger "Authors aggregate built"
    initLog appLogger "Start building Stats aggregate…"
    appStats   <- Stats.buildStats conn
    initLog appLogger "Stats aggregate built"
    initLog appLogger "Application instanciated successfully"
    flushInitLog appLogger
    -- Return the foundation
    return App {..}

-- | Convert our foundation to a WAI Application by calling @toWaiAppPlain@ and
-- applyng some additional middlewares.
makeApplication :: App -> IO Application
makeApplication foundation = do
    logWare <- mkRequestLogger def
        { outputFormat =
            if appDetailedRequestLogging $ appSettings foundation
                then Detailed True
                else Apache
                        (if appIpFromHeader $ appSettings foundation
                            then FromFallback
                            else FromSocket)
        , destination = Logger $ loggerSet $ appLogger foundation
        }

    -- Create the WAI application and apply middlewares
    appPlain <- toWaiAppPlain foundation
    return $ logWare $ defaultMiddlewaresNoLogging appPlain

-- | Warp settings for the given foundation value.
warpSettings :: App -> Settings
warpSettings foundation =
      setPort (appPort $ appSettings foundation)
    $ setHost (appHost $ appSettings foundation)
    $ setOnException (\_req e ->
        when (defaultShouldDisplayException e) $ messageLoggerSource
            foundation
            (appLogger foundation)
            $(qLocation >>= liftLoc)
            "yesod"
            LevelError
            (toLogStr $ "Exception from Warp: " ++ show e))
      defaultSettings

-- | For yesod devel, return the Warp settings and WAI Application.
getApplicationDev :: IO (Settings, Application)
getApplicationDev = do
    settings <- getAppSettings
    foundation <- makeFoundation settings
    wsettings <- getDevSettings $ warpSettings foundation
    app <- makeApplication foundation
    return (wsettings, app)

getAppSettings :: IO AppSettings
getAppSettings = loadAppSettings [configSettingsYml] [] useEnv

-- | main function for use by yesod devel
develMain :: IO ()
develMain = develMainHelper getApplicationDev

-- | The @main@ function for an executable running this site.
appMain :: IO ()
appMain = do
    -- Get the settings from all relevant sources
    settings <- loadAppSettingsArgs
        -- fall back to compile-time values, set to [] to require values at runtime
        [configSettingsYmlValue]

        -- allow environment variables to override
        useEnv

    -- Generate the foundation from the settings
    foundation <- makeFoundation settings

    -- Generate a WAI Application from the foundation
    app <- makeApplication foundation

    -- Run the application with Warp
    runSettings (warpSettings foundation) app


--------------------------------------------------------------
-- Functions for DevelMain.hs (a way to run the app from GHCi)
--------------------------------------------------------------
getApplicationRepl :: IO (Int, App, Application)
getApplicationRepl = do
    settings <- getAppSettings
    foundation <- makeFoundation settings
    wsettings <- getDevSettings $ warpSettings foundation
    app1 <- makeApplication foundation
    return (getPort wsettings, foundation, app1)

shutdownApp :: App -> IO ()
shutdownApp _ = return ()


---------------------------------------------
-- Functions for use in development with GHCi
---------------------------------------------

-- | Run a handler
handler :: Handler a -> IO a
handler h = getAppSettings >>= makeFoundation >>= flip unsafeHandler h
