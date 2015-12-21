
module Handler.Order where

import Import
import Web.Stripe
import Web.Stripe.Charge
import Web.Stripe.Error

lookupQuantity :: ProductId -> OrderCookie -> Int
lookupQuantity p (OrderCookie c) = case find ((==) p . fst) c >>= return . snd of
    Just a -> a
    Nothing -> 0

query :: Handler [(ProductId, Text, Money, Int)]
query = do
    d <- getDeployment
    cookie <- lookupCookie "order"
    case parseOrder =<< cookie of
        Just oc@(OrderCookie cookie') -> do
            xs <- runDB $ select $ from $ \(c `InnerJoin` p) -> do
                on (c ^. CategoryId ==. p ^. ProductCategory)
                where_ (p ^. ProductId `in_` valList (fmap fst cookie')
                        &&. val d ==. c ^. CategoryDeployment)
                return
                    ( p ^. ProductId
                    , p ^. ProductName
                    , p ^. ProductPrice
                    )
            let addq (Value a, Value b, Value c) = (a, b, c, lookupQuantity a oc)
            return $ fmap addq xs
        Nothing -> return []

address :: Maybe Address -> AForm Handler Address
address a = Address
    <$> aopt textField "Name" (addressName <$> a)
    <*> areq textField "Address Line 1" (addressLineone <$> a)
    <*> aopt textField "Address Line 2" (addressLinetwo <$> a)
    <*> areq textField "Town" (addressTown <$> a)
    <*> areq textField "County" (addressCounty <$> a)
    <*> areq textField "Postcode" (addressPostcode <$> a)

bothForm :: Maybe (Address, Phone) -> Form (Address, Phone)
bothForm m = renderDivs $ (,)
    <$> address (fst <$> m)
    <*> areq phoneField "Phone Number" (snd <$> m)

phoneForm :: Maybe Phone -> Form Phone
phoneForm p = renderDivs $ areq phoneField "Phone Number" p

queryStripeConfig :: EntityField Deployment Text -> Handler Text
queryStripeConfig field = do
    did <- getDeployment
    result <- runDB $ select $ from $ \d -> do
        where_ (d ^. DeploymentId ==. val did)
        return (d ^. field)
    return $ case result of
        ((Value key):[]) -> key
        _ -> error "queryStripeConfig"

checkout :: Money -> Widget
checkout (Money amount) = do
    addScriptRemote "https://checkout.stripe.com/checkout.js"
    key <- handlerToWidget $ queryStripeConfig DeploymentStripePublic
    $(widgetFile "checkout")

runStripe :: Handler (Either StripeError (StripeReturn CreateCharge))
runStripe = do
    token <- runInputPost $ TokenId <$> ireq textField "co-token"
    amount <- runInputPost $ ireq intField "co-amount"
    secret <- queryStripeConfig DeploymentStripeSecret
    let config = StripeConfig . StripeKey . encodeUtf8 $ secret
    liftIO $ stripe config $ createCharge (Amount amount) GBP -&- token

stripeError :: StripeError -> Handler Html
stripeError err = defaultLayout $ toWidget [whamlet|Error: #{show err}|]

getOrderR :: Handler Html
getOrderR = handleOrder Nothing

handleOrder :: Maybe Widget -> Handler Html
handleOrder m = do
    rows <- query
    fw <- case m of
        Just a -> return a
        Nothing -> do
            c <- lookupCookie "deliver"
            case maybe False (== "true") c of
                True -> return . fst =<< generateFormPost (bothForm Nothing)
                False -> return . fst =<< generateFormPost (phoneForm Nothing)
    let co = checkout (Money 232)
    defaultLayout $ do
        setTitle "Order"
        $(widgetFile "order")


postOrderR :: Handler Html
postOrderR = do
    c <- lookupCookie "deliver"
    if maybe False (== "true") c then postOrderDeliver else postOrderCollect

postOrderCollect :: Handler Html
postOrderCollect = do
    ((fr, fw), _) <- runFormPost $ phoneForm Nothing
    case fr of
        FormSuccess phone -> do
            sr <- runStripe
            case sr of
                Left e -> stripeError e
                Right _ -> saveOrder phone Nothing
        _ -> handleOrder $ Just fw

postOrderDeliver :: Handler Html
postOrderDeliver = do
    ((fr, fw), _) <- runFormPost $ bothForm Nothing
    case fr of
        FormSuccess (addr, phone) -> do
            sr <- runStripe
            case sr of
                Left e -> stripeError e
                Right _ -> runDB (insert addr) >>= saveOrder phone . Just
        _ -> handleOrder $ Just fw

saveOrder :: Phone -> Maybe AddressId -> Handler Html
saveOrder p ma = do
    d <- getDeployment
    u <- maybeAuthId
    o <- runDB $ insert $ Order d u ma p
    ps <- query
    _ <- forM ps $ \(pid, _, c, q) ->
        runDB $ insert $ OrderLine o pid c q
    redirect OrderCompleteR

getOrderCompleteR :: Handler Html
getOrderCompleteR = do
    deleteCookie "order" "/"
    defaultLayout $ setTitle "Thank You" >> toWidget [whamlet|Success|]
