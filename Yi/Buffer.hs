{-# OPTIONS -fffi -#include YiUtils.h #-}
-- 
-- Copyright (C) 2004 Don Stewart - http://www.cse.unsw.edu.au/~dons
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation; either version 2 of
-- the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
-- General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
-- 02111-1307, USA.
-- 

--
-- | An interface to a one dimensional mutable 'Buffer', providing
-- cursor movement and editing commands
--

module Yi.Buffer where

import Data.IORef

import Prelude      hiding      ( IO )
import GHC.IOBase               ( IO(..) )
import GHC.Base
import GHC.Word                 ( Word8 )

import Data.Unique              ( Unique, newUnique )
import Control.Concurrent.MVar

import IO                       ( hFileSize, hClose, hFlush, IOMode(..) )
import System.IO                ( openBinaryFile )

import Data.Array.MArray        ( newArray_, newListArray )
import Data.Array.Base          ( STUArray(..) )
import Data.Array.IO            ( IOUArray, hGetArray, hPutArray )

import Foreign.C.Types          ( CSize )

-- ---------------------------------------------------------------------
--
-- | The 'Buffer' class defines editing operations over one-dimensional
-- mutable buffers, which maintain a current /point/.
--
--
class Buffer a where

    -- | Construct a new buffer initialised with the supplied name and list
    newB  :: FilePath -> [Char] -> IO a

    -- | Construct a new buffer filled with contents of file
    hNewB :: FilePath -> IO a

    -- | Write buffer into file
    hPutB :: a -> FilePath -> IO ()

    -- | String name of this buffer
    nameB :: a -> String

    -- | Unique key of this buffer
    keyB :: a -> Unique

    ------------------------------------------------------------------------

    -- | Number of characters in the buffer
    sizeB      :: a -> IO Int

    -- | Extract the current point
    pointB     :: a -> IO Int

    -- | Return the contents of the buffer as a list
    elemsB     :: a -> IO [Char]

    -- | Return @n@ elems starting a @i@ of the buffer as a list
    nelemsB    :: a -> Int -> Int -> IO [Char]

    ------------------------------------------------------------------------

    -- | Move point in buffer to the given index
    moveTo     :: a -> Int -> IO ()

    -- | Move point -1
    leftB       :: a -> IO ()
    leftB a     = leftN a 1

    -- | Move cursor -n
    leftN       :: a -> Int -> IO ()
    leftN a n   = pointB a >>= \p -> moveTo a (p - n)

    -- | Move cursor +1
    rightB      :: a -> IO ()
    rightB a    = rightN a 1

    -- | Move cursor +n
    rightN      :: a -> Int -> IO ()
    rightN a n = pointB a >>= \p -> moveTo a (p + n)

    ------------------------------------------------------------------------

    -- | Read the character at the current point
    readB      :: a -> IO Char

    -- | Read the character at the given index
    readAtB    :: a -> Int -> IO Char

    -- | Write an element into the buffer at the current point
    writeB     :: a -> Char -> IO ()

    -- | Write an element at the given index
    writeAtB   :: a -> Int -> Char -> IO ()

    ------------------------------------------------------------------------

    -- | Insert the character at current point, extending size of buffer
    insertB    :: a -> Char -> IO ()

    -- | Insert the list at current point, extending size of buffer
    insertN    :: a -> [Char] -> IO ()

    ------------------------------------------------------------------------

    -- | Delete the character at current point, shrinking size of buffer
    deleteB    :: a -> IO ()

    -- | Delete @n@ characters forward from the current point
    deleteN    :: a -> Int -> IO ()

    -- | Delete @n@ characters backwards from the current point
    -- deleteNback :: a -> Int -> IO ()

    -- | Delete characters forwards to index
    -- deleteTo    :: a -> Int -> IO ()

    ------------------------------------------------------------------------
    -- Line based editing

    -- | Return true if the current point is the start of a line
    atSol       :: a -> IO Bool

    -- | Return true if the current point is the end of a line
    atEol       :: a -> IO Bool

    -- | True if point at start of file
    atSof       :: a -> IO Bool

    -- | True if point at end of file
    atEof       :: a -> IO Bool
    
    -- | Move point to start of line
    moveToSol   :: a -> IO ()

    -- | Offset from start of line
    offsetFromSol :: a -> IO Int

    -- | Index of start of line 
    indexOfSol    :: a -> IO Int

    -- | Index of end of line 
    indexOfEol    :: a -> IO Int

    -- | Move point to end of line
    moveToEol   :: a -> IO ()

    -- | Move @x@ chars back, or to the sol, whichever is less
    moveXorSol  :: a -> Int -> IO ()

    -- | Move @x@ chars forward, or to the eol, whichever is less
    moveXorEol  :: a -> Int -> IO ()

    -- | Delete (back) to start of line
    -- deleteToSol :: a -> IO ()

    -- | Delete to end of line
    deleteToEol :: a -> IO ()

    -- | Delete the entire line the point is in
    -- deleteLn    :: a -> IO ()

    -- | Move point up one line
    lineUp      :: a -> IO ()

    -- | Move point down one line
    lineDown    :: a -> IO ()

    -- | Return the current line number
    curLn       :: a -> IO Int

-- ---------------------------------------------------------------------
--
-- | Fast buffer based on the implementation of 'Handle' in
-- 'GHC.IOBase' and 'GHC.Handle'. The buffer itself is stored as a
-- mutable byte array.
--
-- In the concurrent world, buffers are locked during use.  This is done
-- by wrapping an MVar around the buffer which acts as a mutex over
-- operations on the buffer.
--

-- TODO add attributes hash: isModified, isVisible etc

data FBuffer = 
        FBuffer FilePath        -- immutable name
                Unique          -- immutable unique key
                !(MVar (IORef FBuffer_))

data FBuffer_ = FBuffer_ {
        bufBuf   :: RawBuffer  -- ^ raw memory in the heap
       ,bufPnt   :: !Int       -- ^ current position
       ,bufLen   :: !Int       -- ^ length of contents
       ,bufSize  :: !Int       -- ^ raw size of ba
     }

type RawBuffer = MutableByteArray# RealWorld

instance Eq FBuffer where
   (FBuffer _ u _) == (FBuffer _ v _)     = u == v

instance Show FBuffer where
    showsPrec _ (FBuffer f _ _) = showString $ "\"" ++ f ++ "\""

-- ---------------------------------------------------------------------
-- | Construction

-- | Get a new 'FBuffer' filled from FilePath.
-- Based on GHC's Utils\/StringBuffer.hs
--
hNewFBuffer :: FilePath -> IO FBuffer
hNewFBuffer f = do
    h    <- openBinaryFile f ReadMode
    size <- hFileSize h
    let size_i = fromIntegral size
        r_size = size_i + 2048 -- TODO
    arr <- newArray_ (0,r_size-1)    -- has a MutableByteArray# inside
    r <- if size_i == 0 then return 0 else hGetArray h arr size_i -- empty file?
    hClose h -- SimonM says "hClose explicitly when you can."
    if (r /= size_i)
        then ioError (userError $ "Short read of file: " ++ f)
        else case unsafeCoerce# arr of  -- please forgive me. destruct IOUArray
            STUArray _ _ bytearr# -> do
                ref <- newIORef (FBuffer_ bytearr# 0 size_i r_size)
                mv  <- newMVar ref
                u   <- newUnique
                return (FBuffer f u mv)

--
-- | Write contents of buffer into specified file
--
hPutFBuffer_ :: FBuffer_ -> FilePath -> IO ()
hPutFBuffer_ (FBuffer_ bytearr _ end _) f = do
    h <- openBinaryFile f WriteMode
    case unsafeCoerce# (STUArray 0 (end-1) bytearr) of  -- construct IOUArray
            arr -> do hPutArray h arr end       -- copies bytearr.
                      hFlush h >> hClose h

--
-- | New FBuffer filled from string.
--
stringToFBuffer :: String -> String -> IO FBuffer
stringToFBuffer nm s = do
    let size_i = length s   -- bad for big strings...
        r_size = size_i + 2048 -- TODO
    arr <- newListArray (0,r_size-1) (map (fromIntegral.ord) s) :: IO (IOUArray Int Word8)
    case unsafeCoerce# arr of       -- TODO get rid of Coerce
        STUArray _ _ bytearr# -> do
            ref <- newIORef (FBuffer_ bytearr# 0 size_i r_size)
            mv  <- newMVar ref
            u   <- newUnique
            return (FBuffer nm u mv)

-- ---------------------------------------------------------------------
--
-- | Write string into buffer, return the index of the next point
-- TODO slow.
--
writeChars :: RawBuffer -> [Char] -> Int -> IO Int
writeChars _ []     i = return i 
writeChars b (c:cs) i = writeCharToBuffer b i c >>= writeChars b cs 
{-# INLINE writeChars #-}

--
-- | read @n@ chars from buffer @b@, starting at @i@
-- Slower, more allocs:
--      readChars b n i = mapM (readCharFromBuffer b) [i .. i+n-1]
--
-- strict. is this bad?
--
readChars :: RawBuffer -> Int -> Int -> IO [Char]
readChars b (I# n) (I# i) = do
    let lim = i +# n
    let loop j | j >=# lim  = return []
               | otherwise = do
                    c  <- readCharFromBuffer b j
                    cs <- loop ( j +# 1# )
                    return $! c : cs
    loop i
{-# INLINE readChars #-}

--
-- | Copy chars around the buffer. Return the final index.
-- *Assumes the limits are correct*
--
shiftChars :: RawBuffer -> Int -> Int -> Int -> IO Int
shiftChars b src dst len = 
    c_memcpy_shift b src dst (fromIntegral len) >> return (dst + len)

foreign import ccall unsafe "memcpy_shift"
   c_memcpy_shift :: RawBuffer -> Int -> Int -> CSize -> IO ()

{-
shiftChars b (I# src) (I# dst) (I# l) = do
    let loop 0# _ j = return (I# j)
        loop n  i j = copyCharFromTo b i j >> loop (n -# 1#) (i +# 1#) (j +# 1#)
    loop l src dst
{-# INLINE shiftChars #-}

--
-- | Copy a character to another location in the buffer
--
copyCharFromTo :: RawBuffer -> Int# -> Int# -> IO ()
copyCharFromTo slab src dst = IO $ \st ->
    case readCharArray# slab src st of 
        (# st', c #) -> case writeCharArray# slab dst c st' of
                st'' -> (# st'', () #)
{-# INLINE copyCharFromTo #-}
-}

--
-- | Read a 'Char' from a 'RawBuffer'. Return character
--
-- TODO could use indexCharArray# :: ByteArr# -> Int# -> Char#
--
readCharFromBuffer :: RawBuffer -> Int# -> IO Char
readCharFromBuffer slab off = IO $ \st -> 
    case readCharArray# slab off st of (# st', c #) -> (# st', C# c #)
{-# INLINE readCharFromBuffer #-}

--
-- | Write a 'Char' into a 'RawBuffer', 
-- Stolen straight from GHC. (Write 8-bit character; offset in bytes)
-- TODO ** we're screwed if the buffer is too small, so realloc
--
writeCharToBuffer :: RawBuffer -> Int -> Char -> IO Int
writeCharToBuffer slab (I# off) (C# c) = IO $ \st -> 
    case writeCharArray# slab off c st of st' -> (# st', I# (off +# 1#) #)
{-# INLINE writeCharToBuffer #-}

-- ---------------------------------------------------------------------
--
-- | 'FBuffer' is a member of the 'Buffer' class, providing fast
-- indexing operations. It is implemented in terms of a mutable byte
-- array.
--

instance Buffer FBuffer where

    -- newB :: String -> [Char] -> IO a
    newB = stringToFBuffer

    -- hNewB :: FilePath -> IO a
    hNewB = hNewFBuffer

    -- hPutB :: a -> FilePath -> IO ()
    hPutB (FBuffer _ _ mv) f = readMVar mv >>=
        readIORef >>= \fb -> hPutFBuffer_ fb f

    -- nameB :: a -> String
    nameB (FBuffer f _ _) = f

    -- keyB :: a -> Unique
    keyB (FBuffer _ u _) = u

    -- sizeB      :: a -> IO Int
    sizeB (FBuffer _ _ mv) = readMVar mv >>= 
        readIORef >>= \(FBuffer_ _ _ n _) -> return n

    -- pointB     :: a -> IO Int
    pointB (FBuffer _ _ mv) = readMVar mv >>=
        readIORef >>= \(FBuffer_ _ p _ _) -> return p

    ------------------------------------------------------------------------

    -- elemsB     :: a -> IO [Char]
    elemsB (FBuffer _ _ mv) = readMVar mv >>=
        readIORef >>= \(FBuffer_ b _ n _) -> readChars b n 0

    -- nelemsB    :: a -> Int -> Int -> IO [Char]
    nelemsB (FBuffer _ _ mv) n i = readMVar mv >>=
        readIORef >>= \(FBuffer_ b _ e _) -> do
            let i' = inBounds i e
                n' = min (e-i') n
            readChars b n' i'

    ------------------------------------------------------------------------

    -- moveTo     :: a -> Int -> IO ()
    moveTo (FBuffer _ _ mv) i = withMVar mv $ \ref ->
        modifyIORef ref $ \fb@(FBuffer_ _ _ e _) ->
            let i' = inBounds i e in fb { bufPnt=i' }


    -- readB      :: a -> IO Char
    readB (FBuffer _ _ mv) = withMVar mv $ \ref -> do
        (FBuffer_ b (I# p) _ _) <- readIORef ref
        readCharFromBuffer b p

    -- readAtB :: a -> Int -> IO Char
    readAtB (FBuffer _ _ mv) i = withMVar mv $ \ref -> do
        (FBuffer_ b _ e _) <- readIORef ref
        let (I# i') = inBounds i e in readCharFromBuffer b i'

    -- writeB :: a -> Char -> IO ()
    writeB (FBuffer _ _ mv) c = withMVar mv $ \ref ->
        modifyIORefIO ref $ \fb@(FBuffer_ b p _ _) -> do
            writeCharToBuffer b p c
            return fb

    -- writeAtB   :: a -> Int -> Char -> IO ()
    writeAtB (FBuffer _ _ mv) i c = withMVar mv $ \ref -> 
        modifyIORefIO ref $ \fb@(FBuffer_ b _ e _) -> do
            let i' = inBounds i e
            writeCharToBuffer b i' c
            return fb

    ------------------------------------------------------------------------

    -- insertB :: a -> Char -> IO ()
    insertB a c = insertN a [c]

    -- insertN :: a -> [Char] -> IO ()
    insertN (FBuffer _ _ mv) cs = withMVar mv $ \ref ->
        modifyIORefIO ref $ \fb@(FBuffer_ buf p e _) -> do
            let len = min (e-p) e
                dst = p+length cs
            i <- shiftChars buf p dst len
            j <- writeChars buf cs p
            return $ fb { bufLen=max i j }

    ------------------------------------------------------------------------

    -- deleteB    :: a -> IO ()
    deleteB a = deleteN a 1

    -- deleteN    :: a -> Int -> IO ()
    deleteN (FBuffer _ _ mv) n = withMVar mv $ \ref ->
        modifyIORefIO ref $ \fb@(FBuffer_ buf p e _) -> do
            let src = inBounds (p + n) e
                len = inBounds (e-p-n) e
            i  <- shiftChars buf src p len
            let p' | p == 0    = p     -- go no further!
                   | i == p    = p-1   -- shift back if at eof
                   | otherwise = p
            return $ fb { bufPnt=p', bufLen=i }

    ------------------------------------------------------------------------

    -- atSol       :: a -> IO Bool -- or at start of file
    atSol a = do p <- pointB a
                 if p == 0 then return True
                           else do c <- readAtB a (p-1)
                                   return (c == '\n')

    -- atEol       :: a -> IO Bool -- or at end of file
    atEol a = do p <- pointB a
                 e <- sizeB a
                 if p == max 0 (e-1)
                        then return True
                        else do c <- readB a
                                return (c == '\n')

    -- atEof       :: a -> IO Bool
    atEof a = do p <- pointB a
                 e <- sizeB a
                 return (p == max 0 (e-1))

    -- atSof       :: a -> IO Bool
    atSof a = do p <- pointB a
                 return (p == 0)

    ------------------------------------------------------------------------ 

    -- moveToSol   :: a -> IO ()
    moveToSol a = sizeB a >>= moveXorSol a

    -- offsetFromSol :: a -> IO Int
    offsetFromSol a = do
        i <- pointB a
        moveToSol a
        j <- pointB a
        moveTo a i
        return (i - j)

    -- indexOfSol   :: a -> IO Int
    indexOfSol a = do
        i <- pointB a
        moveToSol a
        j <- pointB a
        moveTo a i
        return j

    -- indexOfEol   :: a -> IO Int
    indexOfEol a = do
        i <- pointB a
        moveToEol a
        j <- pointB a
        moveTo a i
        return j

    -- moveToEol   :: a -> IO ()
    moveToEol a = sizeB a >>= moveXorEol a

    -- moveXorSol  :: a -> Int -> IO ()
    moveXorSol a x
        | x <= 0    = return ()
        | otherwise = do
            let loop 0 = return ()
                loop i = do sol <- atSol a
                            if sol then return () 
                                   else leftB a >> loop (i-1)
            loop x

    -- moveXorEol  :: a -> Int -> IO ()
    moveXorEol a x
        | x <= 0    = return ()
        | otherwise = do
            let loop 0 = return ()
                loop i = do eol <- atEol a
                            if eol then return () 
                                   else rightB a >> loop (i-1)
            loop x

    ------------------------------------------------------------------------

    -- deleteToEol :: a -> IO ()
    deleteToEol a = do
        p <- pointB a
        moveToEol a
        q <- pointB a
        c <- readB a
        let r = fromEnum $ c /= '\n' -- correct for eof
        moveTo a p
        deleteN a (max 0 (q-p+r)) 

    -- ---------------------------------------------------------------------
    -- Line based movement and friends

    -- lineUp :: a -> IO ()
    lineUp b = do
        x <- offsetFromSol b
        moveToSol b
        leftB b
        moveToSol b
        moveXorEol b x

    -- lineDown :: a -> IO ()
    lineDown b = do
        x <- offsetFromSol b
        moveToEol b
        rightB b
        moveXorEol b x  

    -- curLn :: a -> IO Int
    curLn (FBuffer _ _ mv) = withMVar mv $ \ref -> do
        (FBuffer_ b (I# p) _ _) <- readIORef ref
        let loop 0# lc = return (I# lc)
            loop i  lc = do c <- readCharFromBuffer b i
                            if c == '\n' then loop (i -# 1#) (lc +# 1#)
                                         else loop (i -# 1#) lc
        loop p 1#

------------------------------------------------------------------------

-- | calculate whether a move is in bounds.
inBounds :: Int -> Int -> Int
inBounds i end | i <= 0    = 0
               | i >= end  = max 0 (end - 1)
               | otherwise = i
    
--
-- | Just like 'modifyIORef', but the action may also do IO
--
modifyIORefIO :: IORef a -> (a -> IO a) -> IO ()
modifyIORefIO ref f = writeIORef ref =<< f =<< readIORef ref

