-- 
-- Copyright (c) 2004 Don Stewart - http://www.cse.unsw.edu.au/~dons
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
-- | Y I -- as the name suggests ;) -- uses vi as its default key
-- bindings. Feel free to write your own bindings in ~/.yi/Keymap.hs.
-- You must provide a function 'keymap' of type: Char -> Action
--

module Yi.Keymap ( keymap ) where

import Yi.Core
import Yi.UI        -- hack, just for now, so we can see key defns

import Data.Char
import Control.Monad

-- vi is a modeful editor, so we store some state. TODO design?
--
import Data.IORef
import System.IO.Unsafe     ( unsafePerformIO )

-- ---------------------------------------------------------------------
-- | Lets remember what editor mode we are in
--
data Mode = C     -- ^ command mode
          | I     -- ^ insert mode
          | E     -- ^ ex mode

-- | By default, vi starts in command mode
--
mode :: IORef Mode
mode = unsafePerformIO $ newIORef C

beginInsert, beginCommand, beginEx :: IO ()

beginInsert  = writeIORef mode I
beginCommand = writeIORef mode C
beginEx      = writeIORef mode E

-- ---------------------------------------------------------------------
--
-- This function must be implemented by any user keybinding
--
keymap :: Char -> Action
keymap c = readIORef mode >>= flip key c 

-- ---------------------------------------------------------------------
-- | Actual lexer
--
key :: Mode -> Char -> Action

-- 
-- * Command mode
--
key C 'h'  = leftOrSolE 1
key C 'j'  = downE
key C 'k'  = upE
key C 'l'  = rightOrEolE 1
key C '$'  = eolE
key C '0'  = solE
key C '|'  = solE
key C 'i' = beginInsert
key C ':' = msgClrE       >> msgE ":"     >> beginEx 
key C 'x' = deleteE
key C 'a' = rightOrEolE 1                 >> beginInsert
key C 'A' = eolE                          >> beginInsert
key C 'O' = solE          >> insertE '\n' >> beginInsert
key C 'o' = eolE          >> insertE '\n' >> beginInsert
key C 'J' = eolE          >> deleteE      >> insertE ' '

key C c | c == keyPPage = upScreenE
        | c == keyNPage = downScreenE
        | c == '\6'     = downScreenE
        | c == '\2'     = upScreenE
        | c == keyUp    = upE
        | c == keyDown  = downE
        | c == keyLeft  = leftOrSolE 1
        | c == keyRight = rightOrEolE 1

key C 'D' = killE
key C 'd' = do c <- getcE ; when (c == 'd') $ solE >> killE >> deleteE
key C 'r' = getcE >>= writeE
key C 'Z' = do c <- getcE ; when (c == 'Z') quitE
key C '>' = do c <- getcE
               when (c == '>') $ solE >> mapM_ insertE (replicate 4 ' ')

key C '~' = do c <- readE
               let c' = if isUpper c then toLower c else toUpper c
               writeE c'

key C '\23' = nextWinE

-- ---------------------------------------------------------------------
-- * Insert mode
--
key I '\27'  = leftOrSolE 1 >> beginCommand  -- ESC

key I c | c == keyPPage = upScreenE
        | c == keyNPage = downScreenE

key I c  = do 
        (_,s,_) <- bufInfoE
        when (s == 0) $ insertE '\n' -- vi behaviour at start of file
        insertE c

-- ---------------------------------------------------------------------
-- * Ex mode
-- accumulate keys until esc or \n, then try to work out what was typed
--
key E k = msgClrE >> loop [k]
  where
    loop [] = do msgE ":"
                 c <- getcE
                 if c == '\8' || c == keyBackspace
                    then msgClrE >> beginCommand  -- deleted request
                    else loop [c]
    loop w@(c:cs) 
        | c == '\8'         = deleteWith cs
        | c == keyBackspace = deleteWith cs
        | c == '\27' = msgClrE >> beginCommand  -- cancel 
        | c == '\13' = execEx (reverse cs) >> beginCommand
        | otherwise  = do msgE (':':reverse w)
                          c' <- getcE
                          loop (c':w)

    execEx :: String -> Action
    execEx "w"   = viWrite
    execEx "q"   = closeE
    execEx "q!"  = closeE
    execEx "wq"  = viWrite >> quitE
    execEx "n"   = nextBufW
    execEx "N"   = nextBufW
    execEx "p"   = prevBufW
    execEx "P"   = prevBufW
    execEx "sp"  = splitE
    execEx ('e':' ':f) = fnewE f
    execEx cs    = viCmdErr cs

    deleteWith []     = msgClrE >> msgE ":"      >> loop []
    deleteWith (_:cs) = msgClrE >> msgE (':':cs) >> loop cs

-- anything we've missed
key _  _  = nopE

-- ---------------------------------------------------------------------
-- | Try and write a file in the manner of vi\/vim
--
viWrite :: Action
viWrite = do 
    (f,s,_) <- bufInfoE 
    fwriteE
    msgE $ show f++" "++show s ++ "C written"

--
-- | An invalid command
--
viCmdErr :: [Char] -> Action
viCmdErr s = msgE $ "The "++s++ " command is unknown."
