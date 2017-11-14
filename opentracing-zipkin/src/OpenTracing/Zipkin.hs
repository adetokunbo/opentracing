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
{-# LANGUAGE TupleSections         #-}

module OpenTracing.Zipkin
    ( ZipkinContext
    , ctxTraceID
    , ctxSpanID
    , ctxParentSpanID
    , ctxFlags
    , ctxBaggage

    , Flag(..)
    , hasFlag

    , Env(envPRNG)
    , envTraceID128bit
    , envSampler
    , newEnv

    , zipkinTracer
    )
where

import           Control.Lens
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Data.Bool               (bool)
import           Data.Hashable           (Hashable)
import           Data.HashMap.Strict     (HashMap)
import qualified Data.HashMap.Strict     as HashMap
import           Data.HashSet            (HashSet)
import qualified Data.HashSet            as HashSet
import           Data.Maybe
import           Data.Monoid
import           Data.Text               (Text, isPrefixOf)
import           Data.Word
import           GHC.Generics            (Generic)
import           OpenTracing.Propagation
import           OpenTracing.Sampling    (Sampler (runSampler))
import           OpenTracing.Span        hiding (Sampled)
import qualified OpenTracing.Span        as Span
import           OpenTracing.Types
import           System.Random.MWC


type SpanID  = Word64

-- XXX: not sure if we actually need flags other than 'Debug'
data Flag
    = Debug
    | SamplingSet
    | Sampled
    | IsRoot
    deriving (Eq, Show, Generic, Ord)

instance Hashable Flag


data ZipkinContext = ZipkinContext
    { ctxTraceID      :: TraceID
    , ctxSpanID       :: SpanID
    , ctxParentSpanID :: Maybe SpanID
    , _ctxFlags       :: HashSet Flag
    , _ctxBaggage     :: HashMap Text Text
    }

instance HasSampled ZipkinContext where
    ctxSampled = lens sa sbt
      where
        sa s | HashSet.member Sampled (_ctxFlags s) = Span.Sampled
             | otherwise                            = Span.NotSampled

        sbt s Span.Sampled    = s { _ctxFlags = HashSet.insert Sampled (_ctxFlags s) }
        sbt s Span.NotSampled = s { _ctxFlags = HashSet.delete Sampled (_ctxFlags s) }

instance Propagation ZipkinContext where
    _TextMap = prism' fromCtx toCtx
      where
        fromCtx ZipkinContext{..} = HashMap.fromList . catMaybes $
              Just ("x-b3-traceid", view hexText ctxTraceID)
            : Just ("x-b3-spanid" , view hexText ctxSpanID)
            : fmap (("x-b3-parentspanid",) . view hexText) ctxParentSpanID
            : Just ("x-b3-sampled", if HashSet.member Sampled _ctxFlags then "true" else "false")
            : Just ("x-b3-flags"  , if HashSet.member Debug   _ctxFlags then "1"    else "0")
            : map (Just . over _1 ("ot-baggage-" <>)) (HashMap.toList _ctxBaggage)

        toCtx m = ZipkinContext
            <$> (HashMap.lookup "x-b3-traceid" m >>= preview _Hex . knownHex)
            <*> (HashMap.lookup "x-b3-spanid"  m >>= preview _Hex . knownHex)
            <*> (Just $ HashMap.lookup "x-b3-parentspanid" m >>= preview _Hex . knownHex)
            <*> pure (HashSet.fromList $ catMaybes
                    [ HashMap.lookup "x-b3-sampled" m
                        >>= \case "true" -> Just Sampled
                                  _      -> Nothing
                    , HashMap.lookup "x-b3-flags" m
                        >>= \case "1" -> Just Debug
                                  _   -> Nothing
                    ]
                )
            <*> pure (HashMap.filterWithKey (\k _ -> "ot-baggage-" `isPrefixOf` k) m)


hasFlag :: Flag -> ZipkinContext -> Bool
hasFlag f = HashSet.member f . _ctxFlags


data Env = Env
    { envPRNG           :: GenIO
    , _envTraceID128bit :: Bool
    , _envSampler       :: Sampler
    }

newEnv :: MonadIO m => Sampler -> m Env
newEnv samp = do
    prng <- liftIO createSystemRandom
    return Env
        { envPRNG           = prng
        , _envTraceID128bit = True
        , _envSampler       = samp
        }

zipkinTracer :: MonadIO m => Env -> SpanOpts ZipkinContext -> m (Span ZipkinContext)
zipkinTracer r = flip runReaderT r . start

start :: (MonadIO m, MonadReader Env m) => SpanOpts ZipkinContext -> m (Span ZipkinContext)
start so@SpanOpts{spanOptOperation,spanOptRefs,spanOptTags} = do
    ctx <- do
        p <- findParent <$> liftIO (freezeRefs spanOptRefs)
        case p of
            Nothing -> freshContext so
            Just p' -> fromParent   (refCtx p')
    newSpan ctx spanOptOperation spanOptRefs spanOptTags

newTraceID :: (MonadIO m, MonadReader Env m) => m TraceID
newTraceID = do
    Env{..} <- ask
    hi <- if _envTraceID128bit then
              Just <$> liftIO (uniform envPRNG)
          else
              pure Nothing
    lo <- liftIO $ uniform envPRNG
    return TraceID { traceIdHi = hi, traceIdLo = lo }

newSpanID :: (MonadIO m, MonadReader Env m) => m SpanID
newSpanID = ask >>= liftIO . uniform . envPRNG

freshContext :: (MonadIO m, MonadReader Env m) => SpanOpts ZipkinContext -> m ZipkinContext
freshContext SpanOpts{spanOptOperation,spanOptSampled} = do
    trid <- newTraceID
    spid <- newSpanID
    smpl <- asks _envSampler

    flags <- bool mempty (HashSet.singleton Sampled) <$> case spanOptSampled of
        Nothing -> (runSampler smpl) trid spanOptOperation
        Just s  -> pure $ review sampled s

    return ZipkinContext
        { ctxTraceID      = trid
        , ctxSpanID       = spid
        , ctxParentSpanID = Nothing
        , _ctxFlags       = flags
        , _ctxBaggage     = mempty
        }

fromParent :: (MonadIO m, MonadReader Env m) => ZipkinContext -> m ZipkinContext
fromParent p = do
    spid <- newSpanID
    return ZipkinContext
        { ctxTraceID      = ctxTraceID p
        , ctxSpanID       = spid
        , ctxParentSpanID = Just $ ctxSpanID p
        , _ctxFlags       = _ctxFlags p
        , _ctxBaggage     = mempty
        }

makeLenses ''ZipkinContext
makeLenses ''Env
