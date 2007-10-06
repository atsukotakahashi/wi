module Yi.Eval (
        -- * Eval\/Interpretation
        evalE,
        jumpToErrorE,
        consoleKeymap,
) where

import Control.Monad
import Control.Monad.Trans
import Data.Array
import GHC.Exts ( unsafeCoerce# )
import Prelude hiding (error)
import System.Directory
import Text.Regex.Posix
import Yi.Core
import Yi.Debug
import Yi.Editor
import Yi.Kernel
import Yi.Keymap
import Yi.Interact hiding (write)
import Yi.Event
import Yi.Buffer
import Yi.Buffer.HighLevel

evalToStringE :: String -> YiM String
evalToStringE string = withKernel $ \kernel -> do
  result <- compileExpr kernel ("show (" ++ string ++ ")")
  case result of
    Nothing -> return ""
    Just x -> return (unsafeCoerce# x)

-- | Evaluate some text and show the result in the message line.
evalE :: String -> YiM ()
evalE s = evalToStringE s >>= msgE



jumpToE :: String -> Int -> Int -> YiM ()
jumpToE filename line column = do
  bs <- readEditor $ findBufferWithName filename -- FIXME: should find by associated file-name
  case bs of
    [] -> do found <- lift $ doesFileExist filename
             if found 
               then fnewE filename
               else error "file not found"
    (b:_) -> switchToBufferOtherWindowE b
  withBuffer $ do gotoLn line
                  moveXorEol column


parseErrorMessage :: String -> Maybe (String, Int, Int)
parseErrorMessage ln = do
  result :: (Array Int String) <- ln =~~ "^(.+):([0-9]+):([0-9]+):.*$"
  return (result!1, read (result!2), read (result!3))

parseErrorMessageB :: BufferM (String, Int, Int)
parseErrorMessageB = do
  ln <- readLnB
  let Just location = parseErrorMessage ln
  return location

jumpToErrorE :: YiM ()
jumpToErrorE = do
  (f,l,c) <- withBuffer parseErrorMessageB
  jumpToE f l c

prompt :: String
prompt = "Yi> "

consoleKeymap :: Keymap
consoleKeymap = do event (Event KEnter [])
                   write $ do x <- withBuffer readLnB
                              case parseErrorMessage x of
                                Just (f,l,c) -> jumpToE f l c
                                Nothing -> do withBuffer $ do
                                                p <- pointB
                                                botB
                                                p' <- pointB
                                                when (p /= p') $
                                                   insertN ("\n" ++ prompt ++ x)
                                                insertN "\n" 
                                                pt <- pointB
                                                insertN "Yi> "
                                                bm <- getBookmarkB "errorInsert"
                                                setMarkPointB bm pt
                                              execE $ dropWhile (== '>') $ dropWhile (/= '>') $ x
