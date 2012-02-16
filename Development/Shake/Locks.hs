
module Development.Shake.Locks(
    Lock, newLock, withLock,
    Var, newVar, readVar, modifyVar, modifyVar_,
    Barrier, newBarrier, signalBarrier, waitBarrier,
    Resource, newResource, acquireResource, releaseResource
    ) where

import Control.Concurrent
import Control.Monad


---------------------------------------------------------------------
-- LOCK

-- | Like an MVar, but has no value
newtype Lock = Lock (MVar ())
instance Show Lock where show _ = "Lock"

newLock :: IO Lock
newLock = fmap Lock $ newMVar ()

withLock :: Lock -> IO a -> IO a
withLock (Lock x) = withMVar x . const


---------------------------------------------------------------------
-- VAR

-- | Like an MVar, but must always be full
newtype Var a = Var (MVar a)
instance Show (Var a) where show _ = "Var"

newVar :: a -> IO (Var a)
newVar = fmap Var . newMVar

readVar :: Var a -> IO a
readVar (Var x) = readMVar x

modifyVar :: Var a -> (a -> IO (a, b)) -> IO b
modifyVar (Var x) f = modifyMVar x f

modifyVar_ :: Var a -> (a -> IO a) -> IO ()
modifyVar_ (Var x) f = modifyMVar_ x f


---------------------------------------------------------------------
-- BARRIER

-- | Starts out empty, then is filled exactly once
newtype Barrier a = Barrier (MVar a)
instance Show (Barrier a) where show _ = "Barrier"

newBarrier :: IO (Barrier a)
newBarrier = fmap Barrier newEmptyMVar

signalBarrier :: Barrier a -> a -> IO ()
signalBarrier (Barrier x) = putMVar x

waitBarrier :: Barrier a -> IO a
waitBarrier (Barrier x) = readMVar x


---------------------------------------------------------------------
-- RESOURCE

-- | A finite resource, see 'withResource' for details.
data Resource = Resource String Int (Var (Int,[(Int,IO ())]))
instance Show Resource where show (Resource name _ _) = "Resource " ++ name


-- | Create a new finite resource, given a name (for error messages) and a quantity of the resource that exists.
--   See 'withResource' for details.
newResource :: String -> Int -> IO Resource
newResource name mx = do
    when (mx < 0) $
        error $ "You cannot create a resource named " ++ name ++ " with a negative quantity, you used " ++ show mx
    var <- newVar (mx, [])
    return $ Resource name mx var


acquireResource :: Resource -> Int -> IO ()
acquireResource r@(Resource name mx var) want
    | want < 0 = error $ "You cannot acquire a negative quantity of " ++ show r ++ ", requested " ++ show want
    | want > mx = error $ "You cannot acquire more than " ++ show mx ++ " of " ++ show r ++ ", requested " ++ show want
    | otherwise = join $ modifyVar var $ \(available,waiting) ->
        if want <= available then
            return ((available - want, waiting), return ())
        else do
            bar <- newBarrier
            return ((available, waiting ++ [(want,signalBarrier bar ())]), waitBarrier bar)


-- | You should only ever releaseResource that you obtained with acquireResource.
releaseResource :: Resource -> Int -> IO ()
releaseResource (Resource name mx var) i = modifyVar_ var $ \(available,waiting) -> f (available+i) waiting
    where
        f i ((wi,wa):ws) | wi <= i = wa >> f (i-wi) ws
                         | otherwise = do (i,ws) <- f i ws; return (i,(wi,wa):ws)
        f i [] = return (i, [])
