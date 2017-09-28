{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE StrictData            #-}
{-# LANGUAGE TemplateHaskell       #-}

module OpenTracing.Simple
    ( Sampled(..)

    , Context
    , ctxTraceID
    , ctxSpanID
    , ctxSampled
    , ctxBaggage

    , Env
    , newEnv

    , simpleTracer
    , simpleReporter
    )
where

import           Control.Lens               hiding (Context, (.=))
import           Control.Monad.Reader
import           Data.Aeson                 hiding (Error)
import           Data.Aeson.Encoding
import           Data.ByteString.Lazy.Char8 (putStrLn)
import qualified Data.CaseInsensitive       as CI
import           Data.Foldable              (toList)
import           Data.Hashable
import           Data.HashMap.Strict        (HashMap)
import qualified Data.HashMap.Strict        as HashMap
import           Data.Monoid
import           Data.Text                  (Text, isPrefixOf, toLower)
import           Data.Text.Encoding         (decodeUtf8, encodeUtf8)
import qualified Data.Text.Lazy.Builder     as TB
import qualified Data.Text.Lazy.Builder.Int as TB
import qualified Data.Text.Read             as Text
import           Data.Word
import           GHC.Generics               (Generic)
import           GHC.Stack                  (prettyCallStack)
import           OpenTracing.Class
import           OpenTracing.Sampling
import           OpenTracing.Types
import           Prelude                    hiding (putStrLn)
import           System.Random.MWC


type TraceID = Word64
type SpanID  = Word64

type Context = SimpleContext

data SimpleContext = SimpleContext
    { ctxTraceID  :: TraceID
    , ctxSpanID   :: SpanID
    , ctxSampled' :: Sampled
    , _ctxBaggage :: HashMap Text Text
    } deriving (Eq, Show, Generic)

instance Hashable SimpleContext

instance HasSampled SimpleContext where
    ctxSampled = lens ctxSampled' (\s a -> s { ctxSampled' = a })

instance ToJSON SimpleContext where
    toEncoding c = pairs $
           "trace_id" .= ctxTraceID  c
        <> "span_id"  .= ctxSpanID   c
        <> "sampled"  .= ctxSampled' c
        <> "baggage"  .= _ctxBaggage c

    toJSON c = object
        [ "trace_id" .= ctxTraceID  c
        , "span_id"  .= ctxSpanID   c
        , "sampled"  .= ctxSampled' c
        , "baggage"  .= _ctxBaggage c
        ]


instance AsCarrier (TextMap SimpleContext) SimpleContext where
    _Carrier = prism' fromCtx toCtx
      where
        fromCtx c@SimpleContext{..} = TextMap . HashMap.fromList $
              ("ot-tracer-traceid", review _ID ctxTraceID)
            : ("ot-tracer-spanid" , review _ID ctxSpanID)
            : ("ot-tracer-sampled", view (ctxSampled . re _Sampled) c)
            : map (over _1 ("ot-baggage-" <>)) (HashMap.toList _ctxBaggage)

        toCtx (TextMap m) = SimpleContext
            <$> (HashMap.lookup "ot-tracer-traceid" m >>= preview _ID)
            <*> (HashMap.lookup "ot-tracer-spanid"  m >>= preview _ID)
            <*> (HashMap.lookup "ot-tracer-sampled" m >>= preview _Sampled)
            <*> pure (HashMap.filterWithKey (\k _ -> "ot-baggage-" `isPrefixOf` k) m)


instance AsCarrier (HttpHeaders SimpleContext) SimpleContext where
    _Carrier = prism' fromCtx toCtx
      where
        fromCtx
            = HttpHeaders
            . map (bimap (CI.mk . encodeUtf8) encodeUtf8)
            . HashMap.toList
            . fromTextMap
            . (review _Carrier :: Context -> TextMap Context)

        toCtx
            = (preview _Carrier :: TextMap Context -> Maybe Context)
            . TextMap
            . HashMap.fromList
            . map (bimap (toLower . decodeUtf8 . CI.original) decodeUtf8)
            . fromHttpHeaders


data Env = Env
    { envPRNG     :: GenIO
    , _envSampler :: Sampler TraceID IO
    }

newEnv :: MonadIO m => Sampler TraceID IO -> m Env
newEnv sampler = Env <$> liftIO createSystemRandom <*> pure sampler

instance MonadIO m => MonadTrace SimpleContext (ReaderT Env m) where
    traceStart = start

instance MonadIO m => MonadReport SimpleContext m where
    traceReport = report

simpleTracer :: Env -> Interpret (MonadTrace SimpleContext) MonadIO
simpleTracer r = Interpret $ \m -> runReaderT m r

simpleReporter :: Interpret (MonadReport SimpleContext) MonadIO
simpleReporter = Interpret id

--------------------------------------------------------------------------------
-- Internal

start :: (MonadIO m, MonadReader Env m) => SpanOpts Context -> m (Span Context)
start so@SpanOpts{..} = do
    ctx <- case spanOptRefs of
               []    -> freshContext so
               (p:_) -> fromParent p
    newSpan ctx spanOptOperation spanOptRefs spanOptTags

report :: MonadIO m => FinishedSpan Context -> m ()
report = liftIO . putStrLn . encodingToLazyByteString . spanE

newTraceID :: (MonadIO m, MonadReader Env m) => m TraceID
newTraceID = asks envPRNG >>= liftIO . uniform

newSpanID :: (MonadIO m, MonadReader Env m) => m SpanID
newSpanID = asks envPRNG >>= liftIO . uniform

_ID :: Prism' Text Word64
_ID = prism' enc dec
  where
    enc = view strict . TB.toLazyText . TB.decimal
    dec = either (const Nothing) (pure . fst) . Text.decimal
{-# INLINE _ID #-}

_Sampled :: Prism' Text Sampled
_Sampled = prism' enc dec
    where
      enc = \case Sampled -> "1"
                  _       -> "0"

      dec = either (const Nothing) id
          . fmap (\(x,_) -> Just $ if x == (1 :: Word8) then Sampled else NotSampled)
          . Text.decimal
{-# INLINE _Sampled #-}

freshContext :: (MonadIO m, MonadReader Env m) => SpanOpts Context -> m Context
freshContext SpanOpts{spanOptOperation,spanOptSampled} = do
    trid <- newTraceID
    spid <- newSpanID
    smpl <- asks _envSampler

    sampled <- case spanOptSampled of
        Nothing         -> liftIO $ smpl trid spanOptOperation
        Just Sampled    -> pure True
        Just NotSampled -> pure False

    return SimpleContext
        { ctxTraceID  = trid
        , ctxSpanID   = spid
        , ctxSampled' = if sampled then Sampled else NotSampled
        , _ctxBaggage = mempty
        }

fromParent :: (MonadIO m, MonadReader Env m) => Reference Context -> m Context
fromParent p = do
    spid <- newSpanID
    return SimpleContext
        { ctxTraceID  = ctxTraceID (refCtx p)
        , ctxSpanID   = spid
        , ctxSampled' = view ctxSampled (refCtx p)
        , _ctxBaggage = mempty
        }

spanE :: FinishedSpan Context -> Encoding
spanE s = pairs $
       pair "operation"  (text $ view spanOperation s)
    <> pair "start"      (utcTime $ view spanStart s)
    <> pair "duration"   (double . realToFrac $ view spanDuration s)
    <> pair "context"    (toEncoding $ view spanContext s)
    <> pair "references" (list refE . toList $ view spanRefs s)
    <> pair "tags"       (list toEncoding . toList $ view spanTags s)
    <> pair "logs"       (list logRecE . reverse $ view spanLogs s)

refE :: Reference Context -> Encoding
refE (ChildOf     ctx) = pairs . pair "child_of"     . toEncoding $ ctx
refE (FollowsFrom ctx) = pairs . pair "follows_from" . toEncoding $ ctx

logRecE :: LogRecord -> Encoding
logRecE r = pairs $
       pair "time"   (utcTime (view logTime r))
    <> pair "fields" (list logFieldE . toList $ view logFields r)

logFieldE :: LogField -> Encoding
logFieldE f = pairs . pair (logFieldLabel f) $ case f of
    Event      x -> text x
    Message    x -> text x
    Stack      x -> string . prettyCallStack $ x
    ErrKind    x -> text x
    LogField _ x -> string (show x)

makeLenses ''SimpleContext
