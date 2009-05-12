{-# LANGUAGE FlexibleInstances, TypeFamilies, TemplateHaskell, DeriveDataTypeable #-}
-- Copyright (c) JP Bernardy 2008
module Yi.Syntax.Haskell where

import Prelude ()
import Data.Maybe
import Data.List (filter, takeWhile, map)
import Yi.IncrementalParse
import Yi.Lexer.Alex
import Yi.Lexer.Haskell
import Yi.Style
import Yi.Syntax.Layout
import Yi.Syntax.Tree
import qualified Yi.Syntax.BList as BL
import Yi.Syntax
import Yi.Prelude
import Prelude ()
import Data.Monoid
import Data.DeriveTH
import Data.Derive.Foldable
import Data.Derive.Data
import Data.Maybe
import Data.Data
import Data.Typeable
import Data.Generics.Schemes

indentScanner :: Scanner (AlexState lexState) (TT)
              -> Scanner (Yi.Syntax.Layout.State Token lexState) (TT)
indentScanner = layoutHandler startsLayout [(Special '(', Special ')'),
                                            (Special '[', Special ']'),
                                            (Special '{', Special '}')] ignoredToken
                         ([(Special '<'), (Special '>'), (Special '.')]) isBrace

-- HACK: We insert the Special '<', '>', '.', that don't occur in normal haskell
-- parsing.

isBrace :: TT -> Bool
isBrace (Tok b _ _) = (Special '{') == b

ignoredToken :: TT -> Bool
ignoredToken (Tok t _ (Posn _ _ _)) = isComment t || t == CppDirective

-- isNoise :: Token -> Bool
isNoise :: (Char -> Bool) -> Token -> Bool
-- isNoise (Special _) = False
isNoise f (Special c) =  f c
-- isNoise _ (ReservedOp _) = False
-- isNoise _ (ReservedOp RightArrow) = False
-- isNoise _ (ReservedOp Equal) = False
-- isNoise _ (VarIdent) = False
-- isNoise _ (Reserved _) = False
isNoise _ (Reserved Let) = False
isNoise _ (Reserved In) = False
-- isNoise _ (CppDirective) = False
isNoise _ (Reserved Module) = False
isNoise _ (Reserved Import) = False
-- isNoise _ (Reserved Where) = False
-- isNoise _ (Reserved As) = False
isNoise _ (Reserved Type) = False
isNoise _ (Reserved Data) = False
--isNoise _ (Reserved NewType) = False
isNoise _ (Reserved Qualified) = False
isNoise _ (Reserved Hiding) = False
isNoise _ (Comment _) = False
isNoise _ (CppDirective) = False
-- isNoise _ (Operator _) = False
isNoise _ _ = True

type Tree t = Program t
type PAtom t = Exp t
type Block t = Exp t

-- | A program is some comments followed by a module and a body
data Program t 
    = Program [t] (Maybe (Program t)) -- a program can be just comments
    | ProgMod ((PModule' t)) (Program t) -- (BL.BList [Exp t])
    | Body [PImport t] (Block t) (Block t)-- (BL.BList [Exp t]) (BL.BList [Exp t])
  deriving (Show, Data, Typeable)

-- | A module
-- note to self, fix module so that the imports can be separated from the module...
data PModule' t = PModule' (PAtom t) (PAtom t) (Exp t) (Exp t)
    deriving (Show, Data, Typeable)

-- | Imported things
data PImport t = PImport (PAtom t) (Exp t) (PAtom t) (Exp t) (Exp t)
    deriving (Show, Data, Typeable)

-- | Exp can be expression or declaration
data Exp t
    = Paren' (PAtom t) (Exp t) (PAtom t) -- A parenthesized expression with comments
    | Block (BL.BList [Exp t]) -- A list of things separated by layout (as in do; etc.)
    | PAtom t [t]
    | PFun (Exp t) (Exp t) t [t] (Exp t)
    | Expr [Exp t]
    | KW t [t] (Exp t)
    | Bin (Exp t) (Exp t)
    | Error t
    | Error' t [t] -- an error with comments following so we never color comments in wrong color
    | Opt (Maybe (Exp t))
    | Modid t [t]
    | Op t [t] (Exp t)
    | Context (Exp t) (Exp t) t [t]
    | PType t [t] (Exp t) (Exp t) t [t] (Exp t)
    | PData t [t] (Exp t) (Exp t) (Exp t)
    | PData' t [t] (Exp t) (Exp t)
    | TC (Exp t) -- type constructor
    | DC (Exp t) -- data constructor
    | PLet t [t] (Exp t) (Exp t)
  deriving (Show, Data, Typeable)

type TTT = Exp TT


$(derive makeFoldable ''PImport)
$(derive makeFoldable ''PModule')
$(derive makeFoldable ''Program)

$(derive makeFoldable ''Exp)
instance IsTree Exp where
   subtrees (Paren' _ (Expr g) _) = g
   subtrees (Block s)     = concat s
   subtrees (Expr a)      = a
--      subtrees (TypeSig _ a) = a
   subtrees _             = []

$(derive makeTypeable ''Tok)
$(derive makeTypeable ''Token)
$(derive makeTypeable ''ReservedType)
$(derive makeTypeable ''Size)
$(derive makeTypeable ''Posn)
$(derive makeTypeable ''OpType)
$(derive makeTypeable ''CommentType)
$(derive makeData ''Tok)
$(derive makeData ''Token)
$(derive makeData ''Size)
$(derive makeData ''Posn)
$(derive makeData ''CommentType)
$(derive makeData ''OpType)
$(derive makeData ''Point)
$(derive makeData ''ReservedType)

isError' :: Exp TT ->[Exp TT]
isError' n = (listify isE' n)
    where isE' (Error _) = True
          isE' (Error' _ _) = True
          isE' _ = False

-- | Search the given list, and return the 1st tree after the given
-- point on the given line.  This is the tree that will be moved if
-- something is inserted at the point.  Precondition: point is in the
-- given line.

-- -- TODO: this should be optimized by just giving the point of the end
-- -- of the line
getIndentingSubtree :: [Exp TT] -> Point -> Int -> Maybe (Exp TT)
getIndentingSubtree roots offset line =
    listToMaybe $ [t | (t,posn) <- takeWhile ((<= line) . posnLine . snd) $ allSubTree'sPosn,
--                    -- it's very important that we do a linear search
--                    -- here (takeWhile), so that the tree is evaluated
--                    -- lazily and therefore parsing it can be lazy.
                   posnOfs posn > offset, posnLine posn == line]
    where allSubTree'sPosn = [(t',posn) | root <- roots, t'@(Block _) <-filter (not . null . toList) (getAllSubTrees root),
                             let (tok:_) = toList t',
                             let posn = tokPosn tok]
-- 
-- -- | given a tree, return (first offset, number of lines).
getSubtreeSpan :: Exp TT -> (Point, Int)
getSubtreeSpan tree = (posnOfs $ first, lastLine - firstLine)
    where bounds@[first, _last] = fmap (tokPosn . assertJust) [getFirstElement tree, getLastElement tree]
          [firstLine, lastLine] = fmap posnLine bounds
          assertJust (Just x) = x
          assertJust _ = error "assertJust: Just expected"

getExprs :: Program TT -> [Exp TT]
getExprs (ProgMod _ b) = getExprs b
getExprs (Body _ exp exp') = [exp, exp']

-- | The parser
parse :: P TT (Tree TT)
parse = pProgram <* eof

-- | Parse a program
pProgram :: Parser TT (Program TT)
pProgram = Program <$> many pComment <*> (optional
            (pBlockOf' ((ProgMod <$> pModule
             <*> pModBody) <|> pBody)))

-- | Parse a body that follows a module
pModBody :: Parser TT (Program TT)
pModBody =  ((Body <$> ((spec '<') *> pImp) <*> (((Block <$> pBlocks some pDTree') <|> (Block <$> pure BL.nil)) <* (spec '>')) <*> ((Block <$> pBlocks many pDTree')))
             <|> (Body <$> (spec '.' *>) pImp <*> ((Block <$> pBlocks some pDTree') <|> (Block <$> pure BL.nil)) <*> (Block <$> pure BL.nil))
             <|> (Body <$> pure [] <*> pEmptyBL <*> pEmptyBL))

pEmptyBL = Block <$> pure BL.nil

-- | Parse a body of a program
pBody :: Parser TT (Program TT)
pBody = Body <$> pImp <*> (pBol *> (Block <$> pBlocks many pDTree')) <*> (Block <$> pure BL.nil)
    where pBol = testNext (\r ->(not $ isJust r) || 
                 (not (((flip elem [(Special '.'),(Special '<')]) . tokT . fromJust) r)))

-- Helper functions for parsing follows
-- | Parse Variables
pVarId :: Parser TT (TTT)
pVarId = pAt (exact' [VarIdent, (Reserved Other), (Reserved As)])

-- | Parse constructors
pConId :: Parser TT TT
pConId = exact' [ConsIdent]

-- | Parse modules
pModid :: Parser TT TTT
pModid = Modid <$> pleaseB' pConId <*> pCom

-- | Parse VarIdent and ConsIdent
pQvarid :: Parser TT TTT
pQvarid = pAt (exact' [VarIdent, ConsIdent, (Reserved Other), (Reserved As)])

-- | Parse an operator using please
ppQvarsym :: Parser TT TTT
ppQvarsym = ppAt $ sym isOperator

-- | Parse a consident
pQtycon :: Parser TT TTT
pQtycon = pAt pConId

-- | Parse many variables
pVars :: Parser TT TTT
pVars = pMany $ pVarId

-- | Parse an operator
pConop ::Parser TT TTT
pConop = pAt $ sym isOperator

-- | Parse a variable, consident or parentheized operator
pQvar :: Parser TT TTT
pQvar = pQvarid 
        <|> pTup ppQvarsym

-- | Parse a variable or parentheized operator
pVar :: Parser TT TTT
pVar = pTup ppQvarsym 
       <|> pVarId

-- | parse a special symbol
sym :: (Token -> Bool) ->Parser TT TT
sym f   = symbol (f . tokT)

-- | Gives a funktion returning Boolean describing if any token in the list is parsed
exact :: [Token] -> (Token ->Bool)
exact = flip elem 

-- | Parse anything that is in the list
exact' :: [Token] -> Parser TT TT
exact' = sym . exact

-- | Parse special tokens
spec :: Char -> Parser TT TT
spec '|' = exact' [ReservedOp Pipe]
spec '=' = exact' [ReservedOp Equal]
spec c   = sym $ isSpecial [c]

-- | Create a special character symbol
newT :: Char -> TT
newT = tokFromT . Special

-- | Parse a special token using please
pleaseSym :: Char -> Parser TT TT
pleaseSym = ((<|>) pErrN) . spec

pleaseB :: Token -> Parser TT TT
pleaseB r = (pleaseB' . exact') [r]

-- | Parse a Tok using please
pleaseB' :: Parser TT TT -> Parser TT TT
pleaseB' = (<|>) pErrN

-- | Parse a Tree tok using please
pleaseC ::Parser TT TTT ->Parser TT TTT
pleaseC = (<|>) (Error' <$> pErrN <*> pCom)

-- | Recover from anything
pErrN :: Parser TT TT
pErrN = (recoverWith $ pure $ newT '!')

-- | Parse anything that is an error
pErr :: Parser TT TTT
pErr = (Error' <$> recoverWith (symbol $ const True) <*> pCom)

-- | Parse an ConsIdent 
ppCons :: Parser TT TTT
ppCons = ppAt $ exact' [ConsIdent]

-- | Parse a keyword
pKW :: Parser TT TT -> Parser TT TTT -> Parser TT TTT
pKW k r = KW <$> k <*> pCom <*> r

-- | Parse an unary operator 
pOP op r = Op <$> exact' op <*> pCom <*> r

-- | Parse many comments
pCom ::Parser TT [TT]
pCom = many $ pComment

-- | Parse comment
pComment :: Parser TT TT
pComment = sym (\x -> isComment x || (CppDirective == x))

-- | Parse something thats optional
pOpt :: Parser TT TTT -> Parser TT TTT
pOpt = ((<$>) Opt) . optional

-- | Parse an atom
pAt :: Parser TT TT -> Parser TT TTT
pAt b = PAtom <$> b <*> pCom

-- | Parse an atom using please
ppAt :: Parser TT TT -> Parser TT TTT
ppAt b = PAtom <$> pleaseB' b <*> pCom

-- | Parse end of line or end token
pEol :: Parser TT ()
pEol = testNext (\r ->(not $ isJust r) || 
                 ((flip elem [(Special ';'), (Special '.'), (Special '>')]) . tokT . fromJust) r)

-- | Parse something separated by, with optional ending
pSepBy :: Parser TT TTT -> Parser TT TTT -> Parser TT TTT
pSepBy r p = Bin <$> pMany (Bin <$> r <*> p) <*> pOpt r

-- | Parse a comma separator
pComma ::Parser TT TTT
pComma = pAt $ spec ','

-- | Parse a comma using please
ppComma :: Parser TT TTT
ppComma = pAt (pleaseB' $ spec ',')

-- | Parse any operator
isOperator ::Token -> Bool
isOperator (Operator _)     = True
isOperator (ReservedOp _)   = True
isOperator (ConsOperator _) = True
isOperator _                = False

-- End of helper functions Parsing different parts follows

-- | Parse a Module declaration
pModule :: Parser TT (PModule' TT)
pModule = (PModule' <$> pAt (exact' [Reserved Module])
                  <*> pAt (pleaseB ConsIdent)
                  <*> pExports
                  <*> ((optional $ spec '.')    *> (Bin <$> pAt (pleaseB $ Reserved Where)) <*> pMany pErr) <* pEmod)
--                   <*> pRest)
    where pExports = pOpt $ pTup $ pSepBy pExport pComma
          pExport = ((optional $ spec '.') *> 
                     (pVarId
                      <|> pEModule
                      <|> (Bin <$> pTup ppQvarsym <*> pOpt helper)
                      <|> (Bin <$> pQtycon <*> pOpt helper)
                      <|> (Error' <$> pErrN <*> pCom)
                     ))
          helper = pTup ((pAt $ exact' [ReservedOp $ OtherOp ".."])
                          <|> (pSepBy pQvarid pComma)
                          <|> (Error' <$> pErrN <*> pCom))
          pEmod = testNext (\r ->(not $ isJust r) || 
                            ((flip elem [(Special '.'), (Special '<'), (Special '>')]) . tokT . fromJust) r)

-- | Parse several imports
pImp :: Parser TT [PImport TT]
pImp = (many (pImp' <* pEol <* (optional $ exact' [(Special '.'),(Special ';')])))
    where pEol' = testNext (\r ->(not $ isJust r) || 
                           ((flip elem [(Special '>')]) . tokT . fromJust) r)
      
-- | Parse one import
-- pImp' :: Parser TT TTT
pImp' = PImport  <$> pAt (exact' [Reserved Import])
                 <*> pOpt (pAt $ exact' [Reserved Qualified])
                 <*> pAt (pleaseB ConsIdent)
                 <*> pOpt (pKW (exact' [Reserved As]) ppCons)
                 <*> pImpSpec
    where pImpSpec = ((Bin <$> (pKW (exact' [Reserved Hiding]) $ pleaseC pImpS) <*> pEnd)
                      <|> (Bin <$> pImpS <*> pEnd)) <|> pEnd
          pImpS    = (pTup (pSepBy pExp' pComma) )
          pExp'    = Bin <$> ((pAt $ sym (\x -> (exact [VarIdent, ConsIdent] x) || isOperator x))
                              <|> pTup ppQvarsym) <*> pOpt pImpS
          pEnd     = pMany pErr

-- | Parse simple types
pSType :: Parser TT TTT
pSType = PType <$> exact' [Reserved Type]     <*> pCom
             <*> (TC <$> ppCons)           <*> pMany pQvarid
             <*> pleaseB (ReservedOp Equal)        <*> pCom
             <*> pleaseC pType <* pEol -- ((spec '.') <|> recoverWith (symbol $ const True)) 

-- | Parse typedeclaration
pType :: Parser TT TTT
pType = Block <$> some (pAtype) `BL.sepBy1` (pAt $ exact' [ReservedOp RightArrow])

pSimpleType :: Parser TT TTT
pSimpleType = (Bin <$> (TC <$> ppCons) <*> pMany pQvarid) <|> pTup pSimpleType -- (Atom <$> sym (exact' [ConsIdent, VarIdent])))

-- | Parse data declarations
pSData :: Parser TT TTT
pSData = PData <$> exact' [Reserved Data]    <*> pCom
               <*> pOpt pContext
               <*> (Bin <$> pSimpleType <*> pMany pErr)
               <*> (pOpt (Bin <$> pSData' <*> pMany pErr)) <* pEol -- (pleaseSym '.')

-- | Parse second half of the data declaration, if there is one
pSData' :: Parser TT TTT
pSData' = (PData' <$> eqW <*> pCom -- either we have standard data, or we have GADT:s
             <*> pleaseC (pConstrs <|> (pBlockOf' (Block <$> many pGadt `BL.sepBy1` spec '.')))
             <*> pOpt pDeriving) <|> pDeriving
    where eqW = (exact' [(ReservedOp Equal),(Reserved Where)])

-- | Parse an GADT declaration
pGadt :: Parser TT TTT
pGadt = ((Bin <$> (DC <$> pQtycon) 
          <*> pOpt (pOP [ReservedOp $ OtherOp "::"]
                    (Bin <$> pOpt pContext <*>
                     (pType <|> (pOP [Operator "!"] pAtype) <|> pErr))))
         <|>  pErr)

-- | Parse a deriving
pDeriving :: Parser TT TTT
pDeriving = (pKW (exact' [Reserved Deriving])
                (pleaseC ((pTup ((Bin <$> pleaseC pQtycon <*> pMany (Bin <$> pComma <*> pleaseC pQtycon)))))
                             <|> pQtycon))

pAtype :: Parser TT TTT
pAtype = pAtype'
         <|> pErr

pAtype' = pQvarid
         <|> (pTup $ pMany pTree') -- ((Bin <$> pType <*> pMany (Bin <$> pComma <*> pType)) <|> (pCom' pRArrow)))
         <|> (pBrack' $ pMany pTree') -- pleaseC pAtype)
--          <|> Atom <$> exact (ReservedOp DoubleRightArrow)

pBtype :: Parser TT TTT
pBtype = pSome pAtype

pContext :: Parser TT TTT
pContext = (Context <$> pOpt pForAll 
            <*> (pClass <|> pTup (pSepBy pClass pComma))
            <*> pleaseB (ReservedOp DoubleRightArrow) <*> pCom)

pClass :: Parser TT TTT
pClass = Bin <$> pQtycon <*> ((pleaseC pVarId) <|> pTup ((Bin <$> (pleaseC pVarId) <*> pMany pAtype')))

-- | Parse for all
pForAll = KW <$> exact' [Reserved Forall] <*> pCom <*> (Bin <$> pVars <*> (ppAt $ exact' [Operator "."]))

pConstrs :: Parser TT TTT
pConstrs = Bin <$> (Bin <$> pOpt pContext <*> pConstr) 
               <*> pMany (pOP [ReservedOp Pipe]
                          (Bin <$> pOpt pContext <*> pConstr))

pConstr :: Parser TT TTT
pConstr = (Bin <$> pOpt pForAll <*> (Bin <$> (Bin <$> (DC <$> pAtype) <*> pMany (strictF pAtype)) <*> pOpt st)
           <|> Bin <$> lrHs <*> pMany (strictF pAtype)
           <|> pErr)
    where lrHs = (pOP [Operator "!"] pAtype)
          st = (pBrace' $ pOpt (Bin <$> pFielddecl <*> pMany (Bin <$> pComma <*> pFielddecl)))

-- | Parse optional strict variables
strictF :: Parser TT TTT -> Parser TT TTT
strictF a = Bin <$> pOpt (pAt $ exact' [Operator "!"]) <*> a

pFielddecl ::Parser TT TTT
pFielddecl = (Bin <$> pVars <*> pOpt (pOP [ReservedOp $ OtherOp "::"]
                                      (pType <|> (KW <$> exact' [Operator "!"] <*> pCom <*> pAtype)  <|> pErr)))

-- | Exporting module
pEModule ::Parser TT TTT
pEModule = KW <$> exact' [Reserved Module] <*> pCom <*> pModid

-- (Body <$> ((spec '<') *> pImp) <*> (((pBlocks some pDTree') <|> pure BL.nil) <* (spec '>')) <*> ((pBlocks many pDTree')))
--            <|> (Body <$> (((pBol *>) pImp)) <*> ((pBlocks some pDTree')) <*> pure BL.nil)

-- | Parse the left hand side of a function
pFunlhs = ((PFun <$> pVar
            <*> pMany (pApat <|> pErr))
           <|> ((PFun <$> pApat <*> (Bin <$> ppAt (sym isOperator) <*> (Bin <$> pleaseC pApat <*> pMany pErr)))))
           <*> pleaseB' (exact' [(ReservedOp Equal),(ReservedOp Pipe)]) <*> pCom
           <*> pFunrhs  <* pEol -- spec '.'

-- | Parse the rhs of a function
pFunrhs = pMany pTree'

-- pVar = pQvar

pApat = -- ((Enter "APAT" pErr)) 
         (Bin <$> pQcon <*> ((pOpt (pOP [ReservedOp $ OtherOp "@"] $ pleaseC pApat))))
--          <|> (Bin <$> pAt (sym isOperator) <*> pOpt pApat)
         <|> pQvarid
--          <|> (Bin <$> pQcon <*> pOpt pApat)

-- | Parse a Let expression
pLet = PLet <$> exact' [Reserved Let] <*> pCom
            <*> (((pleaseSym '<') *>) (Block <$> pBlocks many pDTree')) 
            <*> (((spec '>') *> (ppAt $ exact' [Reserved In])) 
                 <|> (((pAt $ exact' [Reserved In])) <* ((pleaseSym '>')))
                 <|> ((Expr <$> pure []) <* (spec '>')))

--     | PLet t [t] (Tree' t) (Tree' t)

pQcon = pTup ((pMany pGconsym) <|> (pAt $ sym isOperator))

pQconid = pQtycon

pGconsym = pAt (exact' [ReservedOp (OtherOp ":")]) 
--                 <|> pQvar 
--                 <|> (Enter "GCON" pErr)
                <|> pQvarid
                <|> pTup (pMany pGconsym)

pt  = pOpt (Block <$> pBlocks some pDTree') -- Bin <$> pSome pDTree' <*> pOpt ((spec '.') *> (Block <$> pBlocks pDTree'))

-- | Parse many of something
pMany ::Parser TT TTT ->Parser TT TTT
pMany r = Expr <$> many r

pSome ::Parser TT TTT ->Parser TT TTT
pSome r = Expr <$> some r

pDTree' :: Parser TT TTT
pDTree' = (pBlockOf pDTree')
           <|> pTree'

-- | Parse a some of something separated by the token (Special '.')
pBlocks r p   = (r p) `BL.sepBy1` spec '.' -- see HACK above

-- | Parse a block of some something separated by the tok (Special '.')
pBlockOf p  = (Block <$> (pBlockOf' $ pBlocks many p)) -- see HACK above

-- | Parse something surrounded by (Special '<') and (Special '>')
pBlockOf' p = ((spec '<' *> p <* spec '>')) -- see HACK above

-- | Parse paren expression with comments
pTup :: Parser TT TTT -> Parser TT TTT
pTup p = (Paren' <$>  pAt (spec '(')
          <*> p <*> pAt (pleaseSym ')'))

-- | Parse a Tuple without comments
pTuple :: Parser TT TTT -> Parser TT TTT
pTuple p  = (Paren' <$> (PAtom <$> (spec '(') <*> pure [])
             <*> p
             <*> (PAtom <$> (pleaseSym ')') <*> pure []))

-- | Parse a Bracked expression without comments
pBrack :: Parser TT TTT -> Parser TT TTT
pBrack p  = (Paren' <$> (PAtom <$> (spec '[') <*> pure [])
             <*> p
             <*> (PAtom <$> (pleaseSym ']') <*> pure []))

-- | Parse a Braced expression without comments
pBrace :: Parser TT TTT -> Parser TT TTT
pBrace p  = (Paren'  <$> (PAtom <$> (spec '{') <*> pure []) 
             <*> p  
             <*> (PAtom <$> (pleaseSym '}') <*> pure []))

-- | Parse a Braced expression with comments
pBrace' :: Parser TT TTT -> Parser TT TTT
pBrace' p  = (Paren'  <$>  pAt (spec '{') <*> p  <*> pAt (pleaseSym '}'))

-- | Parse a Bracked expression with comments
pBrack' :: Parser TT TTT -> Parser TT TTT
pBrack' p = (Paren'  <$>  pAt (spec '[')  <*> p <*> pAt (pleaseSym ']'))

-- | Parse a Tree' of expressions
pTree' :: P TT TTT
pTree' = (pTup $ pMany pDTree')
          <|> (pBrack' $ pMany pDTree')
          <|> (pBrace' $ pMany pDTree')
          <|> pSType
          <|> pSData
          <|> pLet
--           <|> pFunlhs
          <|> (Error' <$> recoverWith (sym $ not . isNoise (\x -> not $ elem x "})]")) <*> pCom)
          <|> (PAtom <$> sym (isNoise $ flip elem ";,`") <*> pCom)
      -- note that, by construction, '<' and '>' will always be matched, so
      -- we don't try to recover errors with them.

instance SubTree (Exp TT) where
    type Element (Exp TT) = TT
    foldMapToksAfter begin f t0 = work t0
        where work (PAtom t t') = f t 
              work (Error t) = f t
              work (Error' t t') = f t
              work (Block s) = BL.foldMapAfter begin (foldMapToksAfter begin f) s
              work _ = undefined
    foldMapToks f = foldMap (foldMapToks f)

-- Stroke the program

-- TODO: (optimization) make sure we take in account the begin, so we don't return useless strokes
getStrokes :: Point -> Point -> Point -> Tree TT -> [Stroke]
getStrokes point begin _end t0 = trace (show t0) result
    where result = appEndo (getStrokeProg point begin _end t0) []

-- |getStroke Program
getStrokeProg ::  Point -> Point -> Point -> Tree TT -> Endo [Stroke]
getStrokeProg point begin _end prog 
    = case prog of
        (Program c mod)
            ->com c <> funPr mod
        (ProgMod mod body)
            -> getStrokeMod point begin _end mod  <> getStrokeProg point begin _end body
        (Body imps exps exps') 
            -> funImp imps <> getStr point begin _end exps <> getStr point begin _end exps'
  where funMod (Just mod)  = getStrokeMod point begin _end mod
        funMod Nothing     = foldMap id []
        funPr (Just pr)    = getStrokeProg point begin _end pr
        funPr Nothing      = foldMap id []
        funImp imps        = foldMap (getStrokeImp point begin _end) imps
        funExp exps        = BL.foldMapAfter begin (foldMap (getStr point begin _end)) exps 

-- | Get strokes Module for module
getStrokeMod :: Point -> Point -> Point -> PModule' TT -> Endo [Stroke]
getStrokeMod point begin _end (PModule' m na e w)
              | isErrN na = paintAtom errorStyle m <> getStrokes' na <> getStrokes' e <>
                                      getStrokes' w -- <> getStrokes' b
              | isErrN w = paintAtom errorStyle m <> getStrokes' na
                                     <> getStrokes' e <> getStrokes' w -- <> getStrokes' b
              | otherwise = getStrokes' m <> getStrokes' na
                                 <> getStrokes' e <> getStrokes' w
                                 -- <> getStrokes' b
    where getStrokes' r = getStr point begin _end r

-- | Get strokes for Imports
getStrokeImp ::  Point -> Point -> Point -> PImport TT -> Endo [Stroke]
getStrokeImp point begin _end (PImport m qu na t t')
              | isErrN na = paintAtom errorStyle m <> getStrokes' qu
                                      <> getStrokes' t <> getStrokes' t'
              | isErrN t = paintAtom errorStyle m <> getStrokes' qu
                                      <> getStrokes' na
                                      <> getStrokes' t  <> getStrokes' t'
              | isErrN t' = paintAtom errorStyle m <> getStrokes' qu
                                       <> getStrokes' na
                                       <> getStrokes' t  <> getStrokes' t'
              | otherwise = getStrokes' m    <> getStrokes' qu
                                    <> getStrokes' na
                                    <> getStrokes' t  <> getStrokes' t'
    where getStrokes' r = getStr point begin _end r

-- | Get strokes for expressions and declarations
getStr ::Point -> Point -> Point -> Exp TT -> Endo [Stroke]
getStr point begin _end t0 = getStrokes' t0
    where getStrokes' ::Exp TT -> Endo [Stroke]
          getStrokes' (PAtom t c) = tk t <> com c
          getStrokes' (Modid t c) = tk t <> com c
          getStrokes' (Paren' (PAtom l c) g (PAtom r c'))
              | isErr r = errStyle l <> getStrokes' g
              -- left paren wasn't matched: paint it in red.
              -- note that testing this on the "Paren" node actually forces the parsing of the
              -- right paren, undermining online behaviour.
              | (posnOfs $ tokPosn $ l) == point || (posnOfs $ tokPosn $ r) == point - 1
               = pStyle hintStyle l <> com c <> getStrokes' g
                      <> pStyle hintStyle r <> com c'
              | otherwise  = tk l <> com c <> getStrokes' g
                                  <> tk r <> com c'
          getStrokes' (Error t) = errStyle t -- paint in red
          getStrokes' (Error' t c) = errStyle t <> com c
          getStrokes' (Block s) = BL.foldMapAfter begin getStrokesL s
          getStrokes' (PFun f args s c rhs) 
              | isErrN args = foldMap errStyle f <> getStrokes' args
              | isErr s = foldMap errStyle f <> getStrokes' args
              | otherwise = getStrokes' f <> getStrokes' args 
                          <> tk s <> com c <> getStrokes' rhs
          getStrokes' (Expr g) = getStrokesL g
          getStrokes' (Bin l r) = getStrokes' l <> getStrokes' r
          getStrokes' (KW l c r') = tk l <> com c <> getStrokes' r'
          getStrokes' (Op op c r') = tk op <> com c <> getStrokes' r'
          getStrokes' (PType m c na exp eq c' b)
              | isErrN b ||isErrN na || isErr eq
                          = errStyle m <> com c  <> getStrokes' na 
                                       <> getStrokes' exp <> tk eq
                                       <> com c <> getStrokes' b
              | otherwise = tk m <> com c <> getStrokes' na 
                                       <> getStrokes' exp <> tk eq
                                       <> com c' <> getStrokes' b
          getStrokes' (PData m c na exp eq)
              | isErrN exp || isErrN na ||isErrN eq 
                           = errStyle m <> com c <> getStrokes' na
                                        <> getStrokes' eq
              | otherwise = tk m <> com c <> getStrokes' na
                                       <> getStrokes' exp <> getStrokes' eq
          getStrokes' (PData' eq c' b d) =
                tk eq <> com c' <> getStrokes' b
                            <> getStrokes' d
          getStrokes' (PLet l c expr i) = 
                tk l <> com c <> getStrokes' expr <> getStrokes' i
--           getStrokes' (TypeSig e rest  ) = getStrokes' e <> getStrokesL rest
          getStrokes' (Opt (Just l)) =  getStrokes' l 
          getStrokes' (Opt Nothing) = getStrokesL []
          getStrokes' (Context fAll l arr c) = 
                getStrokes' fAll <> getStrokes' l <> tk arr <> com c
          getStrokes' (TC l) = getStrokes' l
          getStrokes' (DC (PAtom l c)) = pStyle dataConstructorStyle l <> com c
--           getStrokes' (DC (Paren' l c co r c')) = getStrokes' (Paren' l c (dc co) r c') -- small hack...
          getStrokes' (DC r) = getStrokes' r -- in case of empty
          getStrokesL = foldMap getStrokes'

-- Stroke helpers follows

tokenToAnnot :: TT -> Maybe (Span String)
tokenToAnnot (Tok t len posn) = case tokenToText t of
    Nothing -> Nothing
    Just x -> Just (Span (posnOfs posn) x (posnOfs posn +~ len))

ts = tokenToStroke

pStyle style = one . (modStroke style) . ts
one x = Endo (x :)
--           dc (Expr ((Atom a):xs)) = Expr ((DC (PAtom a [])):xs)
--           dc xs = xs
paintAtom col (PAtom a c) = pStyle col a <> com c
isErr = isErrorTok . tokT
isErrN t = (any isErr t) || (not $ null $ isError' t)
errStyle = pStyle errorStyle
tokenToStroke :: TT -> Stroke
tokenToStroke = fmap tokenToStyle . tokToSpan
modStroke :: StyleName -> Stroke -> Stroke
modStroke f = fmap (f `mappend`)

com r = (foldMap tk r)

tk t | isErr t = errStyle t
     | otherwise = one (ts t)
