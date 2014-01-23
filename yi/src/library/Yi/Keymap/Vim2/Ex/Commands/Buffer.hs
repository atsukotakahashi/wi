-- :buffer ex command to switch to named or numbered buffer.
module Yi.Keymap.Vim2.Ex.Commands.Buffer
    ( parse
    ) where

import Control.Applicative
import Control.Monad
import Control.Monad.State

import qualified Text.ParserCombinators.Parsec as P

import Yi.Editor
import Yi.Buffer.Misc
import Yi.Buffer.Basic
import Yi.Keymap
import Yi.Keymap.Vim2.Ex.Types
import qualified Yi.Keymap.Vim2.Ex.Commands.Common as Common


parse :: String -> Maybe ExCommand
parse = Common.parseWithBang nameParser $ \ _ bang -> do
    bufIdent <- P.try ( P.many1 P.digit <|> bufferSymbol) <|>
                P.many1 P.space *> P.many P.anyChar <|>
                P.eof *> return ""
    return $ Common.pureExCommand {
        cmdShow = "buffer"
      , cmdAction = EditorA $ do
            unchanged <- withBuffer0 $ gets isUnchangedBuffer
            if bang || unchanged
                then
                    switchToBuffer bufIdent
                else
                    Common.errorNoWrite
      }
  where
    bufferSymbol = P.string "%" <|> P.string "#"


nameParser :: P.GenParser Char () ()
nameParser = do
    void $ P.try ( P.string "buffer") <|>
           P.try ( P.string "buf")    <|>
           P.try ( P.string "bu")     <|>
           P.try ( P.string "b")


switchToBuffer :: String -> EditorM ()
switchToBuffer s =
    case P.parse bufferRef "" s of
        Right ref -> switchByRef ref
        Left _e   -> switchByName s
  where
    bufferRef = BufferRef . read <$> P.many1 P.digit


switchByName :: String -> EditorM ()
switchByName ""      = return ()
switchByName "#"     = switchToBufferWithNameE "" 
switchByName bufName = switchToBufferWithNameE bufName 


switchByRef :: BufferRef -> EditorM () 
switchByRef ref = do
    mBuf <- findBuffer ref
    maybe (return ()) (switchToBufferE . bkey) mBuf
