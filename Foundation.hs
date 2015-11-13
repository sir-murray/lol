module Foundation where

import Import.Base
import Import.Enum
import Model
import Database.Persist.Sql (ConnectionPool, runSqlPool)
import Text.Jasmine (minifym)
import Yesod.Auth.Email
import Yesod.Auth.Message (AuthMessage (InvalidLogin))
import Yesod.Default.Util (addStaticContentExternal)
import Yesod.Core.Types (Logger)
import qualified Yesod.Core.Unsafe as Unsafe
import qualified Network.Wai as Wai

import qualified Network.Mail.Mime as Mail
import Text.Shakespeare.Text (stext)

-- | The foundation datatype for your application. This can be a good place to
-- keep settings and values requiring initialization before your application
-- starts running, such as database connections. Every handler will have
-- access to the data present here.
data App = App
    { appSettings    :: AppSettings
    , appStatic      :: Static -- ^ Settings for static file serving.
    , appConnPool    :: ConnectionPool -- ^ Database connection pool.
    , appHttpManager :: Manager
    , appLogger      :: Logger
    }

instance HasHttpManager App where
    getHttpManager = appHttpManager

-- This is where we define all of the routes in our application. For a full
-- explanation of the syntax, please see:
-- http://www.yesodweb.com/book/routing-and-handlers
--
-- Note that this is really half the story; in Application.hs, mkYesodDispatch
-- generates the rest of the code. Please see the linked documentation for an
-- explanation for this split.
--
-- This function also generates the following type synonyms:
-- type Handler = HandlerT App IO
-- type Widget = WidgetT App IO ()
mkYesodData "App" $(parseRoutesFile "config/routes")

-- | A convenient synonym for creating forms.
type Form x = Html -> MForm (HandlerT App IO) (FormResult x, Widget)

newtype CachedDeploymentId key
    = CachedDeploymentId { unCachedDeploymentId :: key }
    deriving Typeable

getDeployment' :: Handler DeploymentId
getDeployment' = do
    domain <- runInputGet $ ireq textField "domain"
    (Entity deployment _) <- runDB $ getBy404 $ UniqueDomain domain
    return deployment

getDeployment :: Handler DeploymentId
getDeployment = do
    a <- getDeployment'
    let b = return $ CachedDeploymentId a
    c <- cached b
    return $ unCachedDeploymentId c

wrap :: Widget -> Text -> Widget
wrap w "navbar" = do
    maid <- handlerToWidget maybeAuthId
    manager <- handlerToWidget authManager
    $(widgetFile "wrappers/navbar")
wrap w _ = getMessage >>= (\mmsg -> $(widgetFile "wrappers/default-layout"))

-- Please see the documentation for the Yesod typeclass. There are a number
-- of settings which can be configured by overriding methods here.
instance Yesod App where
    -- Controls the base of generated URLs. For more information on modifying,
    -- see: https://github.com/yesodweb/yesod/wiki/Overriding-approot
    approot = ApprootRequest $ \_ r -> maybe ""
        (mappend ("http://" :: Text) . decodeUtf8)
        (lookup "host" . Wai.requestHeaders $ r)

    -- Store session data on the client in encrypted cookies,
    -- default session idle timeout is 120 minutes
    makeSessionBackend _ = Just <$> defaultClientSessionBackend
        120    -- timeout in minutes
        "config/client_session_key.aes"

    defaultLayout widget = do
        -- Can't use getBy404 because the subwidget might be a 404 response already.
        domain <- runInputGet $ ireq textField "domain"
        wrapper <- runDB $ do
            d <- getBy $ UniqueDomain domain
            return $ case d of
                Just (Entity _ (Deployment _ _ w)) -> w
                Nothing -> ""

        pc <- widgetToPageContent $ do
            addStylesheet $ StaticR css_bootstrap_css
            addStylesheet $ StaticR css_base_css
            addScript $ StaticR js_jquery_1_11_3_min_js
            addScript $ StaticR js_bootstrap_min_js
            addScript $ StaticR js_order_js
            wrap widget wrapper
        withUrlRenderer [hamlet|
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <title>#{pageTitle pc}
    <meta name="viewport" content="width=device-width, initial-scale=1">
    ^{pageHead pc}
  <body>
    ^{pageBody pc}
|]

    -- The page to be redirected to when authentication is required.
    authRoute _ = Just $ AuthR LoginR

    isAuthorized ProductR _ = authManager'
    isAuthorized (ProductEditR _) _ = authManager'
    --isAuthorized (AuthR _) _ = return Authorized
    --isAuthorized FaviconR _ = return Authorized
    --isAuthorized RobotsR _ = return Authorized
    isAuthorized _ _ = return Authorized

    -- This function creates static content files in the static folder
    -- and names them based on a hash of their content. This allows
    -- expiration dates to be set far in the future without worry of
    -- users receiving stale content.
    addStaticContent ext mime content = do
        master <- getYesod
        let settings = appSettings master
        addStaticContentExternal
            (if appMinify settings then minifym else Right)
            genFileName
            (appStaticDir settings)
            (StaticR . flip StaticRoute [])
            ext
            mime
            content
      where
        -- Generate a unique filename based on the content itself
        genFileName lbs = "autogen-" ++ base64md5 lbs

    -- What messages should be logged. The following includes all messages when
    -- in development, and warnings and errors in production.
    shouldLog app _source level =
        appShouldLogAll (appSettings app)
            || level == LevelWarn
            || level == LevelError

    makeLogger = return . appLogger

-- How to run database actions.
instance YesodPersist App where
    type YesodPersistBackend App = SqlBackend
    runDB action = do
        master <- getYesod
        runSqlPool action $ appConnPool master

instance YesodPersistRunner App where
    getDBRunner = defaultGetDBRunner appConnPool

instance YesodAuth App where
    type AuthId App = UserId

    -- Where to send a user after successful login
    loginDest _ = HomeR
    -- Where to send a user after logout
    logoutDest _ = HomeR
    -- Override the above two destinations when a Referer: header is present
    -- Maybe use ultimate destination later
    redirectToReferer _ = False

    authenticate creds = runDB $ do
        x <- getBy $ UniqueUser $ credsIdent creds
        return $ case x of
            Just (Entity uid _) -> Authenticated uid
            Nothing -> UserError InvalidLogin

    -- You can add other plugins like BrowserID, email or OAuth here
    authPlugins _ = [authEmail]

    loginHandler = do
        tp <- getRouteToParent
        lift $ authLayout $ do
            setTitle "Login"
            let box = apLogin authEmail tp
            $(widgetFile "login")

    --authHttpManager = getHttpManager
    authHttpManager = error "authHttpManager"

authManager' :: Handler AuthResult
authManager' = do
    maid <- maybeAuthId
    case maid of
        Nothing -> return AuthenticationRequired
        Just aid -> do
            user <- runDB $ get aid
            case user of
                Nothing -> return AuthenticationRequired
                Just u -> if userType u >= userManager
                    then return Authorized
                    else return $ Unauthorized "Managers only"

authManager :: Handler Bool
authManager = authManager' >>= (\a -> case a of
    Authorized -> return True
    _ -> return False)

instance YesodAuthPersist App

-- This instance is required to use forms. You can modify renderMessage to
-- achieve customized and internationalized form validation messages.
instance RenderMessage App FormMessage where
    renderMessage _ _ = defaultFormMessage

instance YesodAuthEmail App where
    type AuthEmailId App = UserId

    afterPasswordRoute _ = HomeR

    addUnverified email verkey = do
        d <- getDeployment
        runDB $ insert $ User d email Nothing userCustomer "" "" (Just verkey) False

    sendVerifyEmail email _ verurl = liftIO $ Mail.renderSendMail $ Mail.simpleMail'
        (Mail.Address Nothing email)
        (Mail.Address Nothing "jonathan.landahl@phpartnership.com")
        "Verify"
         [stext|
             Please confirm your email address by clicking on the link below.

             #{verurl}

             Thank you
         |]

    getVerifyKey = runDB . fmap (join . fmap userVerkey) . get
    setVerifyKey uid key = runDB $ update uid [UserVerkey =. Just key]
    verifyAccount uid = runDB $ do
        mu <- get uid
        case mu of
            Nothing -> return Nothing
            Just _ -> do
                update uid [UserVerified =. True]
                return $ Just uid
    getPassword = runDB . fmap (join . fmap userPassword) . get
    setPassword uid pass = runDB $ update uid [UserPassword =. Just pass]
    getEmailCreds email = runDB $ do
        mu <- getBy $ UniqueUser email
        case mu of
            Nothing -> return Nothing
            Just (Entity uid u) -> return $ Just EmailCreds
                { emailCredsId = uid
                , emailCredsAuthId = Just uid
                , emailCredsStatus = isJust $ userPassword u
                , emailCredsVerkey = userVerkey u
                , emailCredsEmail = email
                }
    getEmail = runDB . fmap (fmap userEmail) . get

unsafeHandler :: App -> Handler a -> IO a
unsafeHandler = Unsafe.fakeHandlerGetLogger appLogger

-- Note: Some functionality previously present in the scaffolding has been
-- moved to documentation in the Wiki. Following are some hopefully helpful
-- links:
--
-- https://github.com/yesodweb/yesod/wiki/Sending-email
-- https://github.com/yesodweb/yesod/wiki/Serve-static-files-from-a-separate-domain
-- https://github.com/yesodweb/yesod/wiki/i18n-messages-in-the-scaffolding
