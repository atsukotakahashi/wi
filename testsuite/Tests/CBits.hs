{-# OPTIONS -fffi #-}
-- Test the fast buffer implementation


module Tests.CBits where

import Yi.Buffer
import Yi.FastBuffer
import Yi.Process       ( popen )

import Data.Unique
import Data.Char
import Data.List

import System.Directory
import System.IO.Unsafe

import Control.Monad
import qualified Control.Exception
import Control.Concurrent
import Control.Concurrent.MVar

import Foreign.C.Types          ( CChar )
import Foreign.Ptr              ( Ptr )

import TestFramework

contents = unsafePerformIO $  do
        s <- readFile "../README"
        forkIO (Control.Exception.evaluate (length s) >> return ())
        return s

------------------------------------------------------------------------

foreign import ccall unsafe "YiUtils.h countlns"
   ccountlns :: Ptr CChar -> Int -> Int -> IO Int

foreign import ccall unsafe "YiUtils.h gotoln"
   cgotoln :: Ptr CChar -> Int -> Int -> Int -> IO Int

foreign import ccall unsafe "YiUtils.h tabwidths"
   ctabwidths :: Ptr CChar -> Int -> Int -> Int -> IO Int

------------------------------------------------------------------------

$(tests "cbits" [d| 

 testCcountLns = do
        b  <- newB "testbuffer" contents :: IO FBuffer
        s  <- sizeB b
        i  <- docount b s
        deleteN b s
        s'  <- sizeB b
        i' <- docount b s'
        insertB b '\n'
        s'' <- sizeB b
        j <- docount b s''
        k <- docount b 0
        assertEqual (i-1) (length . filter (== '\n') $ contents)
        assertEqual 1 i'
        assertEqual 2 j
        assertEqual 1 k

    where
        docount :: FBuffer -> Int -> IO Int
        docount b end = do
            let (FBuffer { rawbuf = mv }) = b
            withMVar mv $ \(FBuffer_ ptr _ _ _) -> ccountlns ptr 0 end

 -- index of first point of line n
 testCgotoln = do
        b <- newB "testbuffer" contents :: IO FBuffer

        -- indicies of all first char after a \n char
        let pure  = map (+1) (findIndices (=='\n') contents)

        -- now see if the fast version matches
        let (FBuffer { rawbuf = mv }) = b
        impure <- withMVar mv $ \(FBuffer_ ptr _ end _) ->
                sequence [ cgotoln ptr 0 end (i+1) | i <- [1 .. length pure] ]

        let n = 20
        let p_n = pure !! n
        i_n <- withMVar mv $ \(FBuffer_ ptr _ end _) -> cgotoln ptr 0 end (n+1+1)

        assertEqual pure impure
        assertEqual p_n  i_n

{-
 test_screenlen = unsafePerformIO $ do
        b <- newB "testbuffer" contents :: IO FBuffer
        return $ assertEqual (nameB b) "testbuffer"
-}

 |])
    
