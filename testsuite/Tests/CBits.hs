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

foreign import ccall unsafe "YiUtils.h countLines"
   ccountlns :: Ptr CChar -> Int -> Int -> IO Int

foreign import ccall unsafe "YiUtils.h findStartOfLineN"
   cgotoln :: Ptr CChar -> Int -> Int -> Int -> IO Int

foreign import ccall unsafe "YiUtils.h expandedLengthOfStr"
   ctabwidths :: Ptr CChar -> Int -> Int -> Int -> IO Int

foreign import ccall unsafe "YiUtils.h strlenWithExpandedLengthN"
   cstrlentabbed :: Ptr CChar -> Int -> Int -> Int -> Int -> IO Int

------------------------------------------------------------------------

$(tests "cbits" [d| 

 testCountLines = do
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
 testFindStartOfLineN = do
        b <- newB "testbuffer" contents :: IO FBuffer

        -- the index of the start of each line, line 1 starts at 0
        let pure  = 0 : (init . map (+1) . (findIndices (== '\n')) $ contents)

        -- now see if the fast version matches
        let (FBuffer { rawbuf = mv }) = b

        impure <- withMVar mv $ \(FBuffer_ ptr _ end _) ->
                sequence [ cgotoln ptr 0 end i | i <- [0 .. length pure-1] ]

        let n   = 20
        let p_n = pure !! n
        i_n <- withMVar mv $ \(FBuffer_ ptr _ end _) -> cgotoln ptr 0 end n

        assertEqual pure impure
        assertEqual p_n  i_n

{-
 test_screenlen = unsafePerformIO $ do
        b <- newB "testbuffer" contents :: IO FBuffer
        return $ assertEqual (nameB b) "testbuffer"
-}

 |])
    
