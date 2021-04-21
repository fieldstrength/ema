{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeApplications #-}

-- | TODO: Refactor this module
module Ema.Server where

import Control.Exception (try)
import Data.LVar (LVar)
import qualified Data.LVar as LVar
import qualified Data.Text as T
import Ema.Route (IsRoute (..))
import NeatInterpolation (text)
import qualified Network.HTTP.Types as H
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai.Handler.WebSockets as WaiWs
import Network.WebSockets (ConnectionException)
import qualified Network.WebSockets as WS

runServerWithWebSocketHotReload ::
  forall model route.
  (Show route, IsRoute route) =>
  Int ->
  LVar model ->
  (model -> route -> LByteString) ->
  IO ()
runServerWithWebSocketHotReload port model render = do
  let settings = Warp.setPort port Warp.defaultSettings
  Warp.runSettings settings $ WaiWs.websocketsOr WS.defaultConnectionOptions wsApp httpApp
  where
    wsApp pendingConn = do
      conn :: WS.Connection <- WS.acceptRequest pendingConn
      WS.withPingThread conn 30 (pure ()) $ do
        subId <- LVar.addListener model
        let log s = putTextLn $ "[" <> show subId <> "] :: " <> s
        log "ws connected"
        let loop = do
              msg <- WS.receiveData conn
              let r :: route =
                    msg
                      & pathInfoFromWsMsg
                      & routeFromPathInfo
                      & fromMaybe (error "invalid route from ws")
              log $ "Browser requests next HTML for: " <> show r
              val <- LVar.listenNext model subId
              WS.sendTextData conn $ routeHtml val r
              log $ "Sent HTML for " <> show r
              loop
        try loop >>= \case
          Right () -> pure ()
          Left (err :: ConnectionException) -> do
            log $ "ws:error " <> show err
            LVar.removeListener model subId
    httpApp req f = do
      (status, v) <- case routeFromPathInfo (Wai.pathInfo req) of
        Nothing ->
          pure (H.status404, "No route")
        Just r -> do
          val <- LVar.get model
          pure (H.status200, routeHtml val r)
      f $ Wai.responseLBS status [(H.hContentType, "text/html")] v
    routeFromPathInfo =
      fromSlug . fmap (fromString . toString)
    routeHtml :: model -> route -> LByteString
    routeHtml m r = do
      render m r <> wsClientShim

-- | Return the equivalent of WAI's @pathInfo@, from the raw path string
-- (`document.location.pathname`) the browser sends us.
pathInfoFromWsMsg :: Text -> [Text]
pathInfoFromWsMsg =
  filter (/= "") . T.splitOn "/" . T.drop 1

-- Browser-side JavaScript code for interacting with the Haskell server
wsClientShim :: LByteString
wsClientShim =
  encodeUtf8
    [text|
        <script>
        // https://stackoverflow.com/a/47614491/55246
        function setInnerHtml(elm, html) {
          elm.innerHTML = html;
          Array.from(elm.querySelectorAll("script")).forEach(oldScript => {
            const newScript = document.createElement("script");
            Array.from(oldScript.attributes)
              .forEach(attr => newScript.setAttribute(attr.name, attr.value));
            newScript.appendChild(document.createTextNode(oldScript.innerHTML));
            oldScript.parentNode.replaceChild(newScript, oldScript);
          });
        }

        function refreshPage() {
          // The setTimeout is necessary, otherwise reload will hang forever (at
          // least on Brave browser)
          // 
          // The delayedRefresh trick (5000 and 2000) is for cases when the
          // server hasn't reloaded fast enough, but the browser hangs forever
          // in reload refresh state.
          //
          // FIXME: This is not enough. Cancel and retry the reload, as it is
          // normal to have longer sessions of ghcid in error state while the
          // user fixes their code.
          setTimeout(function() {
            window.location.reload();
          }, 5000);
          setTimeout(function() {
            window.location.reload();
          }, 2000);
          setTimeout(function() {
            window.location.reload();
          }, 100);
        };

        function init() {
          console.log("ema: Opening ws conn");
          var ws = new WebSocket("ws://" + window.location.host);

          // Call this, then the server will send update *once*. Call again for
          // continous monitoring.
          function watchRoute() {
            ws.send(document.location.pathname);
          };

          ws.onopen = () => {
            console.log("ema: Observing server for changes");
            watchRoute();
          };
          ws.onclose = () => {
            // TODO: Display a message box on page during disconnected state.
            console.log("ema: closed; reconnecting ..");
            setTimeout(init, 1000);
            // refreshPage();
          };
          ws.onmessage = evt => {
            console.log("ema: Resetting HTML body")
            setInnerHtml(document.documentElement, evt.data);
            watchRoute();
          };
          window.onbeforeunload = evt => { ws.close(); };
          window.onpagehide = evt => { ws.close(); };
        };
        
        window.onpageshow = init;
        </script>
    |]
