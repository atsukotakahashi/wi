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
-- | Vi keymap for Yi.
-- Based on version 1.79 (7\/14\/97) of nex\/nvi
--
-- The goal is strict vi emulation
--

module Yi.Keymap.Vi ( keymap, keymapPlus, ViMode ) where

import Yi.Yi         hiding ( keymap )
import Yi.Editor            ( Action )

import Prelude       hiding ( any )

import Data.Char
import Data.List            ( (\\) )
import Data.Maybe           ( fromMaybe )
import qualified Data.Map as M

import Control.Monad        ( replicateM_, when )
import Control.Exception    ( ioErrors, catchJust, try, evaluate )

-- ---------------------------------------------------------------------

-- A vi mode is a lexer that returns a core Action.
type ViMode = Lexer  ViState Action
type ViRegex = Regexp ViState Action

--
-- state threaded through the lexer
--
-- In vi, you may add bindings (:map) to cmd or insert mode. We thus
-- carry around the current cmd and insert lexers in the state. Calls to
-- switch editor modes therefore use the lexers in the state.
--
data ViState =
        St { acc :: [Char]           -- an accumulator, for count, search and ex mode
           , hist:: ([String],Int)   -- ex-mode command history
           , cmd :: ViMode          -- (maybe augmented) cmd mode lexer
           , ins :: ViMode }        -- (maybe augmented) ins mode lexer

--
-- | Top level. Lazily consume all the input, generating a list of
-- actions, which then need to be forced
--
-- NB . if there is a (bad) exception, we'll lose any new bindings.. iorefs?
--    . also, maybe we shouldn't refresh automatically?
--
keymap :: [Char] -> [Action]
keymap cs = setWindowFillE '~' : actions
    where
        (actions,_,_) = execLexer cmd_mode (cs, defaultSt)

-- | default lexer state, just the normal cmd and insert mode. no mappings
defaultSt :: ViState
defaultSt = St { acc = [], hist = ([],0), cmd = cmd_mode, ins = ins_mode }

-- | like keymap, but takes a supplied lexer, which is used to augment the
-- existing lexer. Useful for user-added binds (to command mode only!)
keymapPlus :: ViMode -> [Char] -> [Action]
keymapPlus lexer' cs = actions
    where
        actions = let (ts,_,_) = execLexer cmd_mode' (cs, dfltSt) in ts
        cmd_mode'= cmd_mode >||< lexer'
        dfltSt = St { acc = [], hist = ([],0), cmd = cmd_mode', ins = ins_mode }

------------------------------------------------------------------------

-- The vi lexer is divided into several parts, roughly corresponding
-- to the different modes of vi. Each mode is in turn broken up into
-- separate lexers for each phase of key input in that mode.

-- | command mode consits of simple commands that take a count arg - the
-- count is stored in the lexer state. also the replace cmd, which
-- consumes one char of input, and commands that switch modes.
cmd_mode :: ViMode
cmd_mode = lex_count >||< cmd_eval >||< cmd_move >||< cmd2other >||< cmd_op

--
-- | insert mode is either insertion actions, or the meta \ESC action
--
ins_mode :: ViMode
ins_mode = ins_char >||< ins2cmd

--
-- | replace mode is like insert, except it performs writes, not inserts
--
rep_mode :: ViMode
rep_mode = rep_char >||< rep2cmd

--
-- | ex mode is either accumulating input or, on \n, executing the command
--
ex_mode :: ViMode
ex_mode = ex_char >||< ex_edit >||< ex_hist >||< ex_eval >||< ex2cmd

------------------------------------------------------------------------
-- util

--
-- lookup an fm, getting an action otherwise nopE, and apply it to an
-- integer repetition argument.
--
getCmdFM :: Char -> Int -> M.Map Char (Int -> Action) -> Action
getCmdFM c i fm = let mfn = M.lookup c fm in (fromMaybe (const nopE) mfn) i

--
listToMInt :: [Char] -> Maybe Int
listToMInt [] = Nothing
listToMInt cs = Just $ read cs

--
toInt :: [Char] -> Int
toInt cs = fromMaybe 1 (listToMInt (reverse cs))

------------------------------------------------------------------------
--
-- A lexer to accumulate digits, echoing them to the cmd buffer. This is
-- typically what is needed for integer repetition arguments to commands
--
-- ToDo don't handle 0 properly
--
lex_count :: ViMode
lex_count = digit
    `meta` \[c] st -> (with (msg (c:acc st)),st{acc = c:acc st},Just $ cmd st)
    where
        msg cs = msgE $ (replicate 60 ' ') ++ (reverse cs)

-- ---------------------------------------------------------------------
-- | Movement commands
--
-- The may be invoked directly, or sometimes as arguments to other
-- /operator/ commands (like d).
--
cmd_move :: ViMode
cmd_move = (move_chr >|< (move2chrs +> anyButEsc))
    `meta` \cs st@St{acc=cnt} ->
        (with (msgClrE >> (fn cs cnt)), st{acc=[]}, Just $ cmd st)

    where move_chr  = alt $ M.keys moveCmdFM
          move2chrs = alt $ M.keys move2CmdFM
          fn cs cnt  = case cs of
                         -- 'G' command needs to know Nothing count
                        "G" -> case listToMInt cnt of
                                        Nothing -> botE >> solE
                                        Just n  -> gotoLnE n

                        [c,d] -> let mfn = M.lookup c move2CmdFM
                                     f   = fromMaybe (const (const nopE)) mfn
                                 in f (toInt cnt) d

                        [c]  -> getCmdFM c (toInt cnt) moveCmdFM

                        _    -> nopE

--
-- movement commands
--
moveCmdFM :: M.Map Char (Int -> Action)
moveCmdFM = M.fromList $
-- left/right
    [('h',          left)
    ,('\^H',        left)
    ,(keyBackspace, left)
    ,('\BS',        left)
    ,('l',          right)
    ,(' ',          right)
    ,(keyHome,      const firstNonSpaceE)   -- vim does solE
    ,('^',          const firstNonSpaceE)
    ,('$',          const eolE)
    ,('|',          \i -> solE >> rightOrEolE (i-1))

-- up/down
    ,('k',          up)
    ,(keyUp,        up)
    ,('\^P',        up)
    ,('j',          down)
    ,(keyDown,      down)
    ,('\^J',        down)
    ,('\^L',        const refreshE)
    ,('\^N',        down)
    ,('\r',         down)

-- words
    -- ToDo these aren't quite right, but are nice and simple
    ,('w',          \i -> replicateM_ i $ do
                            moveWhileE (isAlphaNum)      GoRight
                            moveWhileE (not.isAlphaNum)  GoRight )

    ,('b',          \i -> replicateM_ i $ do
                            moveWhileE (isAlphaNum)      GoLeft
                            moveWhileE (not.isAlphaNum)  GoLeft )

-- text
    ,('{',          prevNParagraphs)
    ,('}',          nextNParagraphs)

-- misc
    ,('H',          \i -> downFromTosE (i - 1))
    ,('M',          const middleE)
    ,('L',          \i -> upFromBosE (i - 1))

-- bogus entry
    ,('G',          const nopE)
    ]
    where
        left  i = leftOrSolE i
        right i = rightOrEolE i
        up    i = if i > 100 then gotoLnFromE (-i) else replicateM_ i upE
        down  i = if i > 100 then gotoLnFromE i    else replicateM_ i downE

--
-- more movement commands. these ones are paramaterised by a character
-- to find in the buffer.
--
move2CmdFM :: M.Map Char (Int -> Char -> Action)
move2CmdFM = M.fromList $
    [('f',  \i c -> replicateM_ i $ rightE >> moveWhileE (/= c) GoRight)
    ,('F',  \i c -> replicateM_ i $ leftE  >> moveWhileE (/= c) GoLeft)
    ,('t',  \i c -> replicateM_ i $ rightE >> moveWhileE (/= c) GoRight >> leftE)
    ,('T',  \i c -> replicateM_ i $ leftE  >> moveWhileE (/= c) GoLeft  >> rightE)
    ]

--
-- | Other command mode functions
--
cmd_eval :: ViMode
cmd_eval = (cmd_char >|<
           (char 'r' +> anyButEscOrDel) >|<
           (string ">>" >|< string "<<" >|< string "ZZ" ))

    `meta` \lexeme st@St{acc=count} ->
        let i  = toInt count
            fn = case lexeme of
                    "ZZ"    -> viWrite >> quitE
                    -- todo: fix the unnec. refreshes that happen
                    ">>"    -> do replicateM_ i $ solE >> mapM_ insertE "    "
                                  firstNonSpaceE
                    "<<"    -> do solE
                                  replicateM_ i $
                                    replicateM_ 4 $
                                        readE >>= \k ->
                                            when (isSpace k) deleteE
                                  firstNonSpaceE

                    'r':[x] -> writeE x

                    [c]     -> getCmdFM c i cmdCmdFM -- normal commands

                    _       -> undef (head lexeme)

        in (with (msgClrE >> fn), st{acc=[]}, Just $ cmd st)

    where
        anyButEscOrDel = alt $ any' \\ ('\ESC':delete')
        cmd_char       = alt $ M.keys cmdCmdFM
        undef c = not_implemented c

--
-- cmd mode commands
--
cmdCmdFM :: M.Map Char (Int -> Action)
cmdCmdFM = M.fromList $
    [('\^B',    upScreensE)
    ,('\^F',    downScreensE)
    ,('\^G',    const viFileInfo)
    ,('\^W',    const nextWinE)
    ,('\^Z',    const suspendE)
    ,('D',      const (readRestOfLnE >>= setRegE >> killE))
    ,('J',      const (eolE >> deleteE))    -- the "\n"
    ,('n',      const (searchE Nothing [] GoRight))

    ,('X',      \i -> do p <- getPointE
                         leftOrSolE i
                         q <- getPointE -- how far did we really move?
                         when (p-q > 0) $ deleteNE (p-q) )

    ,('x',      \i -> do p <- getPointE -- not handling eol properly
                         rightOrEolE i
                         q <- getPointE
                         gotoPointE p
                         when (q-p > 0) $ deleteNE (q-p) )

    ,('p',      (\_ -> getRegE >>= \s ->
                        eolE >> insertE '\n' >>
                            mapM_ insertE s >> solE)) -- ToDo insertNE

    ,(keyPPage, upScreensE)
    ,(keyNPage, downScreensE)
    ,(keyLeft,  leftOrSolE)          -- not really vi, but fun
    ,(keyRight, rightOrEolE)
    ]

--
-- | So-called 'operators', which take movement actions as arguments.
--
-- How do we achive this? We look for the known operator chars
-- (op_char), followed by digits and one of the known movement commands.
-- We then consult the lexer table with digits++move_char, to see what
-- movement commands they correspond to. We then return an action that
-- performs the movement, and then the operator. For example, we 'd'
-- command stores the current point, does a movement, then deletes from
-- the old to the new point.
--
-- We thus elegantly achieve things like 2d4j (2 * delete down 4 times)
-- Lazy lexers - you know we're right (tm).
--
cmd_op :: ViMode
cmd_op =((op_char +> digit `star` (move_chr >|< (move2chrs +> anyButEsc))) >|<
         (string "dd" >|< string "yy"))

    `meta` \lexeme st@St{acc=count} ->
        let i  = toInt count
            fn = getCmd lexeme i
        in (with (msgClrE >> fn), st{acc=[]}, Just $ cmd st)

    where
        op_char   = alt $ M.keys opCmdFM
        move_chr  = alt $ M.keys moveCmdFM
        move2chrs = alt $ M.keys move2CmdFM

        getCmd :: [Char] -> Int -> Action
        getCmd lexeme i = case lexeme of
            -- shortcuts
                "dd" -> solE >> killE >> deleteE
                "yy" -> readLnE >>= setRegE

            -- normal ops
                c:ms -> getOpCmd c i ms
                _    -> nopE

        getOpCmd c i ms = (fromMaybe (\_ _ -> nopE) (M.lookup c opCmdFM)) i ms

        -- | operator (i.e. movement-parameterised) actions
        opCmdFM :: M.Map Char (Int -> [Char] -> Action)
        opCmdFM = M.fromList $
            [('d', \i m -> replicateM_ i $ do
                              (p,q) <- withPointMove m
                              deleteNE (max 0 (abs (q - p) + 1))  -- inclusive
             ),
             ('y', \_ m -> do (p,q) <- withPointMove m
                              s <- (if p < q then readNM p q else readNM q p)
                              setRegE s -- ToDo registers not global.
             )
            ,('~', const invertCase) -- not right.
            ]

        -- invert the case of range described by movement @m@
        -- could take 90s on a 64M file.
        invertCase m = do
            (p,q) <- withPointMove m
            mapRangeE (min p q) (max p q) $ \c ->
                if isUpper c then toLower c else toUpper c

        --
        -- A strange, useful action. Save the current point, move to
        -- some location specified by the sequence @m@, then return.
        -- Return the current, and remote point.
        --
        withPointMove :: [Char] -> IO (Int,Int)
        withPointMove ms = do p <- getPointE
                              foldr (>>) nopE (getMove ms)
                              q <- getPointE
                              when (p < q) $ gotoPointE p
                              return (p,q)

        --
        -- lookup movement command to perform .. ToDo should be (cmd st)?
        --
        getMove cs = let (as,_,_) = execLexer (cmd_move >||< lex_count)
                                              (cs, defaultSt)
                     in as

--
-- | Switch to another vi mode.
--
-- These commands are meta actions, as they transfer control to another
-- lexer. Some of these commands also perform an action before switching.
--
cmd2other :: ViMode
cmd2other = modeSwitchChar
    `meta` \[c] st ->
        let beginIns a = (with a, st, Just (ins st))
        in case c of
            ':' -> (with (msgE ":"), st{acc=[':']}, Just ex_mode)
            'R' -> (Nothing, st, Just rep_mode)
            'i' -> (Nothing, st, Just (ins st))
            'I' -> beginIns solE
            'a' -> beginIns $ rightOrEolE 1
            'A' -> beginIns eolE
            'o' -> beginIns $ eolE >> insertE '\n'
            'O' -> beginIns $ solE >> insertE '\n' >> upE
            'c' -> beginIns $ not_implemented 'c'
            'C' -> beginIns $ readRestOfLnE >>= setRegE >> killE
            'S' -> beginIns $ solE >> readLnE >>= setRegE >> killE

            '/' -> (with (msgE "/"), st{acc=['/']}, Just ex_mode)
            '?' -> (with (not_implemented '?'), st{acc=[]}, Just $ cmd st)

            '\ESC'-> (with msgClrE, st{acc=[]}, Just $ cmd st)

            s   -> (with (errorE ("The "++show s++" command is unknown."))
                   ,st, Just $ cmd st)

    where modeSwitchChar = alt ":RiIaAoOcCS/?\ESC"

-- ---------------------------------------------------------------------
-- | vi insert mode
--
ins_char :: ViMode
ins_char = anyButEsc
    `action` \[c] -> Just (fn c)

    where fn c = case c of
                    k | isDel k       -> leftE >> deleteE
                      | k == keyPPage -> upScreenE
                      | k == keyNPage -> downScreenE
                      | k == '\t'     -> mapM_ insertE "    " -- XXX
                    _ -> insertE c

-- switch out of ins_mode
ins2cmd :: ViMode
ins2cmd  = char '\ESC' `meta` \_ st -> (with (leftOrSolE 1), st, Just $ cmd st)

-- ---------------------------------------------------------------------
-- | vi replace mode
--
-- To quote vi:
--  In Replace mode, one character in the line is deleted for every character
--  you type.  If there is no character to delete (at the end of the line), the
--  typed character is appended (as in Insert mode).  Thus the number of
--  characters in a line stays the same until you get to the end of the line.
--  If a <NL> is typed, a line break is inserted and no character is deleted.
--
-- ToDo implement the undo features
--

rep_char :: ViMode
rep_char = anyButEsc
    `action` \[c] -> Just (fn c)
    where fn c = case c of
                    k | isDel k       -> leftE >> deleteE
                      | k == keyPPage -> upScreenE
                      | k == keyNPage -> downScreenE
                    '\t' -> mapM_ insertE "    " -- XXX
                    '\r' -> insertE '\n'
                    _ -> do e <- atEolE
                            if e then insertE c else writeE c >> rightE

-- switch out of rep_mode
rep2cmd :: ViMode
rep2cmd  = char '\ESC' `meta` \_ st -> (Nothing, st, Just $ cmd st)

-- ---------------------------------------------------------------------
-- Ex mode. We also lex regex searching mode here.

-- normal input to ex. accumlate chars
ex_char :: ViMode
ex_char = anyButDelNlArrow
    `meta` \[c] st -> (with (msg c), st{acc=c:acc st}, Just ex_mode)
    where
        anyButDelNlArrow = alt $ any' \\ (enter' ++ delete' ++ ['\ESC',keyUp,keyDown])
        msg c = getMsgE >>= \s -> msgE (s++[c])

-- history editing
-- TODO when you go up, then down, you need 2 keypresses to go up again.
ex_hist :: ViMode
ex_hist = arrow
    `meta` \[key] st@St{hist=(h,i)} ->
                let (s,i') = msg key (h,i)
                in (with (msgE s),st{acc=reverse s,hist=(h,i')}, Just ex_mode)
    where
        msg :: Char -> ([String],Int) -> (String,Int)
        msg key (h,i) = case () of {_
                | null h         -> (":",0)
                | key == keyUp   -> if i < length h - 1
                                    then (h !! i, i+1)
                                    else (last h, length h - 1)
                | key == keyDown -> if i > 0
                                    then (h !! i, i-1)
                                    else (head h, 0)
                | otherwise      -> error "ex_hist: the impossible happened"
            }

        arrow = alt [keyUp, keyDown]

-- line editing
ex_edit :: ViMode
ex_edit = delete
    `meta` \_ st ->
        let cs' = case acc st of [c]    -> [c]
                                 (_:xs) -> xs
                                 []     -> [':'] -- can't happen
        in (with (msgE (reverse cs')), st{acc=cs'}, Just ex_mode)

-- escape exits ex mode immediately
ex2cmd :: ViMode
ex2cmd = char '\ESC'
    `meta` \_ st -> (with msgClrE, st{acc=[]}, Just $ cmd st)

--
-- eval an ex command to an Action, also appends to the ex history
--
ex_eval :: ViMode
ex_eval = enter
    `meta` \_ st@St{acc=dmc} ->
        let c  = reverse dmc
            h  = (c:(fst $ hist st), snd $ hist st) in case c of
        -- regex searching
        ('/':pat) -> (with (searchE (Just pat) [] GoRight)
                     ,st{acc=[],hist=h},Just $ cmd st)

        -- add mapping to command mode
        (_:'m':'a':'p':' ':cs) ->
               let pair = break (== ' ') cs
                   cmd' = uncurry (eval_map st (Left $ cmd st)) pair
               in (with msgClrE, st{acc=[],hist=h,cmd=cmd'}, Just cmd')

        -- add mapping to insert mode
        (_:'m':'a':'p':'!':' ':cs) ->
               let pair = break (== ' ') cs
                   ins' = uncurry (eval_map st (Right $ ins st)) pair
               in (with msgClrE, st{acc=[],hist=h,ins=ins'}, Just (cmd st))

        -- unmap a binding from command mode
        (_:'u':'n':'m':'a':'p':' ':cs) ->
               let cmd' = eval_unmap (Left $ cmd st) cs
               in (with msgClrE, st{acc=[],hist=h,cmd=cmd'}, Just cmd')

        -- unmap a binding from insert mode
        (_:'u':'n':'m':'a':'p':'!':' ':cs) ->
               let ins' = eval_unmap (Right $ ins st) cs
               in (Nothing, st{acc=[],hist=h,ins=ins'}, Just (cmd st))

        -- just a normal ex command
        (_:src) -> (with (fn src), st{acc=[],hist=h}, Just $ cmd st)

        -- can't happen, but deal with it
        [] -> (Nothing, st{acc=[], hist=h}, Just $ cmd st)

    where
      fn ""           = msgClrE

      fn s@(c:_) | isDigit c = do
        e <- try $ evaluate $ read s
        case e of Left _ -> errorE $ "The " ++show s++ " command is unknown."
                  Right lineNum -> gotoLnE lineNum

      fn "w"          = viWrite
      fn ('w':' ':f)  = viWriteTo f
      fn "q"          = do
            b <- isUnchangedE
            if b then closeE
                 else errorE $ "File modified since last complete write; "++
                               "write or use ! to override."
      fn "q!"         = closeE
      fn "$"          = botE
      fn "wq"         = viWrite >> closeE
      fn "n"          = nextBufW
      fn "p"          = prevBufW
      fn ('s':'p':_)  = splitE
      fn ('e':' ':f)  = fnewE f
      fn ('s':'/':cs) = viSub cs

      fn "reboot"     = rebootE     -- !
      fn "reload"     = reloadE     -- !

      fn s            = errorE $ "The "++show s++ " command is unknown."

------------------------------------------------------------------------
--
-- | Given a lexer, a sequence of chars, and another sequence of
-- chars, bind the lhs to the actions produced by the rhs, and augment
-- the lexer with the new binding. (Left == command mode)
--
eval_map :: ViState                 -- ^ current state (including other lexers)
         -> (Either ViMode ViMode)  -- ^ which mode we're tweaking
         -> [Char]                  -- ^ identifier to bind to
         -> [Char]                  -- ^ body of macro, to be expanded
         -> ViMode                  -- ^ resulting augmented mode

eval_map st emode lhs rhs = mode >||< bind
    where
        mode     = either id id emode
        st'      = case emode of
                        Left  cmd' -> st {acc=[], cmd=cmd'}
                        Right ins' -> st {acc=[], ins=ins'}
        (as,_,_) = execLexer mode (rhs, st')
        bind     = string lhs `action` \_ -> Just (foldl (>>) nopE as)

--
-- | Unmap a binding from the keymap (i.e. nopE a lex table entry)
-- Currently we unmap all the way back to the original mode. So you
-- can't stack bindings. This is vi's behaviour too, roughly.
--
eval_unmap :: (Either ViMode ViMode)  -- ^ which vi mode to unmap from
           -> [Char]                  -- ^ identifier to unmap
           -> ViMode                  -- ^ new, depleted mode

eval_unmap emode lhs = mode >||< bind
    where
        mode      = either id id emode
        dflt_mode = either (const cmd_mode) (const ins_mode) emode
        (as,_,_) = execLexer dflt_mode (lhs, defaultSt)
        bind     = case as of
                    [] -> string lhs `action` \_ -> Just nopE -- wasn't bound prior
                    [a]-> string lhs `action` \_ -> Just a    -- bound to just one
                    _  -> string lhs `action` \_ -> Just nopE
                            -- components of the command were bound. too hard

------------------------------------------------------------------------

not_implemented :: Char -> Action
not_implemented c = errorE $ "Not implemented: " ++ show c

-- ---------------------------------------------------------------------
-- Misc functions

viFileInfo :: Action
viFileInfo = 
    do bufInfo <- bufInfoE
       msgE $ showBufInfo bufInfo
    where 
    showBufInfo :: BufferFileInfo -> String
    showBufInfo bufInfo = concat [ show $ bufInfoFileName bufInfo
				 , " Line "
				 , show $ bufInfoLineNo bufInfo
				 , " ["
				 , bufInfoPercent bufInfo
				 , "]"
				 ]


-- | Try to write a file in the manner of vi\/vim
-- Need to catch any exception to avoid losing bindings
viWrite :: Action
viWrite = do
    mf <- fileNameE
    case mf of
        Nothing -> errorE "no file name associate with buffer"
        Just f  -> do
            bufInfo <- bufInfoE
	    let s   = bufInfoFileName bufInfo
            let msg = msgE $ show f ++" "++show s ++ "C written"
            catchJust ioErrors (fwriteToE f >> msg) (msgE . show)

-- | Try to write to a named file in the manner of vi\/vim
viWriteTo :: String -> Action
viWriteTo f = do
    let f' = (takeWhile (/= ' ') . dropWhile (== ' ')) f
    bufInfo <- bufInfoE
    let s   = bufInfoFileName bufInfo
    let msg = msgE $ show f'++" "++show s ++ "C written"
    catchJust ioErrors (fwriteToE f' >> msg) (msgE . show)


-- | Try to do a substitution
viSub :: [Char] -> Action
viSub cs = do
    let (pat,rep') = break (== '/')  cs
        (rep,opts) = case rep' of
                        []     -> ([],[])
                        (_:ds) -> case break (== '/') ds of
                                    (rep'', [])    -> (rep'', [])
                                    (rep'', (_:fs)) -> (rep'',fs)
    case opts of
        []    -> do_single pat rep
        ['g'] -> do_single pat rep
        _     -> do_single pat rep-- TODO

    where do_single p r = do
                s <- searchAndRepLocal p r
                if not s then errorE ("Pattern not found: "++p) else msgClrE

{-
          -- inefficient. we recompile the regex each time.
          -- stupido
          do_line   p r = do
                let loop i = do s <- searchAndRepLocal p r
                                if s then loop (i+1) else return i
                s <- loop (0 :: Int)
                if s == 0 then msgE ("Pattern not found: "++p) else msgClrE
-}

-- ---------------------------------------------------------------------
-- | Handle delete chars in a string
--
{-
clean :: [Char] -> [Char]
clean (_:c:cs) | isDel c = clean cs
clean (c:cs)   | isDel c = clean cs
clean (c:cs) = c : clean cs
clean [] = []
-}

-- | Is a delete sequence
isDel :: Char -> Bool
isDel '\BS'        = True
isDel '\127'       = True
isDel c | c == keyBackspace = True
isDel _            = False

-- ---------------------------------------------------------------------
-- | character ranges
--
digit, delete, enter, anyButEsc :: ViRegex
digit   = alt digit'
enter   = alt enter'
delete  = alt delete'
-- any     = alt any'
anyButEsc = alt $ (keyBackspace : any' ++ cursc') \\ ['\ESC']

enter', any', digit', delete' :: [Char]
enter'   = ['\n', '\r']
delete'  = ['\BS', '\127', keyBackspace ]
any'     = ['\0' .. '\255']
digit'   = ['0' .. '9']

cursc' :: [Char]
cursc'   = [keyPPage, keyNPage, keyLeft, keyRight, keyDown, keyUp]
