{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE Rank2Types #-}
-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2014-2015 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

module CodeGen.SBVC where

import Control.Applicative
import Data.List (intercalate)
import Data.Map (Map)
import Data.Maybe
import Data.Monoid
import Data.SBV
import qualified Data.Map as M

import Cryptol.Eval (ExprOperations(..))
import Cryptol.Eval.Value (BitWord(..), GenValue(..), PPOpts(..), TValue(..), WithBase(..), defaultPPOpts)
import Cryptol.ModuleSystem (ModuleEnv(..), checkExpr, focusedEnv)
import Cryptol.ModuleSystem.Renamer (namingEnv, rename, runRenamer)
import Cryptol.Parser (parseExpr)
import Cryptol.Parser.Position (Range, emptyRange)
import Cryptol.Prims.Eval (BinOp, UnOp)
import Cryptol.Prims.Syntax
import Cryptol.Symbolic.Value () -- for its instance Mergeable (GenValue b w)
import Cryptol.TypeCheck.AST
           (ModName(..), QName(..), Name(..), TVar, Expr, Type(..), Schema(..),
            TCon(..), TC(..), Expr(..), Module(..))
import Cryptol.TypeCheck.Defaulting (defaultExpr)
import Cryptol.TypeCheck.Subst (apSubst)
import Cryptol.Utils.Compare
import Cryptol.Utils.Panic
import Cryptol.Utils.PP (PP(..), Doc, braces, brackets, char, comma, fsep, parens, pp, pretty, punctuate, sep, text)

import qualified Cryptol.Parser.AST as P
import qualified Cryptol.Prims.Eval as Eval
import qualified Cryptol.Eval       as Eval
import qualified Cryptol.Eval.Type  as Eval
import qualified Cryptol.Eval.Env   as Eval
import qualified Cryptol.Utils.PP   as PP

import CodeGen.Types


-- CWord -----------------------------------------------------------------------

-- A type of words with statically-known bit sizes.
data CWord
  = CWord8  SWord8
  | CWord16 SWord16
  | CWord32 SWord32
  | CWord64 SWord64
  | UnsupportedSize Int

instance BitWord SBool CWord where
  packWord bs = case length bs of
    8  -> CWord8  $ fromBitsBE bs
    16 -> CWord16 $ fromBitsBE bs
    32 -> CWord32 $ fromBitsBE bs
    64 -> CWord64 $ fromBitsBE bs
    n  -> UnsupportedSize n
  unpackWord cw = case cw of
    CWord8  w -> blastBE w
    CWord16 w -> blastBE w
    CWord32 w -> blastBE w
    CWord64 w -> blastBE w
    UnsupportedSize n -> panic "CodeGen.SBVC.unpackWord @SBool @CWord"
      [ "Words of width " ++ show n ++ " are not supported." ]

instance Comparable CWord OrderingSymbolic where
  cmp (CWord8  l) (CWord8  r) = cmp l r
  cmp (CWord16 l) (CWord16 r) = cmp l r
  cmp (CWord32 l) (CWord32 r) = cmp l r
  cmp (CWord64 l) (CWord64 r) = cmp l r
  cmp l r
    | cWidth l == cWidth r = panic "CodeGen.SBVC.cmp @CWord"
      [ "Can't compare words of unsupported size " ++ show (cWidth l) ]
    | otherwise = panic "CodeGen.SBVC.cmp @CWord"
      [ "Can't compare words of differing sizes:"
      , show (cWidth l)
      , show (cWidth r)
      ]

mkCWord :: Integer -> Integer -> CWord
mkCWord width value = case width of
  8  -> CWord8  $ fromInteger value
  16 -> CWord16 $ fromInteger value
  32 -> CWord32 $ fromInteger value
  64 -> CWord64 $ fromInteger value
  _  -> UnsupportedSize $ fromInteger width

cWidth :: CWord -> Int
cWidth CWord8 {} = 8
cWidth CWord16{} = 16
cWidth CWord32{} = 32
cWidth CWord64{} = 64
cWidth (UnsupportedSize n) = n

liftUnCWord
  :: UnOp SWord8
  -> UnOp SWord16
  -> UnOp SWord32
  -> UnOp SWord64
  -> Integer -> UnOp CWord
liftUnCWord op8 op16 op32 op64 _ cw = case cw of
  CWord8  w -> CWord8  (op8  w)
  CWord16 w -> CWord16 (op16 w)
  CWord32 w -> CWord32 (op32 w)
  CWord64 w -> CWord64 (op64 w)
  _ -> cw

liftBinCWord
  :: BinOp SWord8
  -> BinOp SWord16
  -> BinOp SWord32
  -> BinOp SWord64
  -> Integer -> BinOp CWord
liftBinCWord op8 op16 op32 op64 _ cl cr = case (cl, cr) of
  (CWord8  l, CWord8  r) -> CWord8  (op8  l r)
  (CWord16 l, CWord16 r) -> CWord16 (op16 l r)
  (CWord32 l, CWord32 r) -> CWord32 (op32 l r)
  (CWord64 l, CWord64 r) -> CWord64 (op64 l r)
  (UnsupportedSize l, UnsupportedSize r) | l == r -> UnsupportedSize l
  _ -> panic "CodeGen.SBVC.liftBinCWord"
    [ "size mismatch"
    , show (cWidth cl)
    , show (cWidth cr)
    ]

-- | Essentially a type alias for all the classes supported by the kinds of
-- words contained in a 'CWord'. Not literally a type alias to avoid the
-- ConstraintKinds extension. Commented-out contexts are ones which we could
-- support but don't for now because we aren't using them yet and don't want to
-- spuriously add imports.
class
  ( SDivisible a
  , FromBits a
  , Polynomial a
  , Bounded a
  , Enum a
  , Eq a
  , Num a
  , Show a
  -- , Arbitrary a
  , Bits a
  -- , NFData a
  -- , Random a
  , SExecutable a
  , Data.SBV.HasKind a
  , PrettyNum a
  , Uninterpreted a
  , Mergeable a
  , OrdSymbolic a
  , EqSymbolic a
  ) => SBVWord a

instance
  ( SDivisible a
  , FromBits a
  , Polynomial a
  , Bounded a
  , Enum a
  , Eq a
  , Num a
  , Show a
  -- , Arbitrary a
  , Bits a
  -- , NFData a
  -- , Random a
  , SExecutable a
  , Data.SBV.HasKind a
  , PrettyNum a
  , Uninterpreted a
  , Mergeable a
  , OrdSymbolic a
  , EqSymbolic a
  ) => SBVWord a

liftBinSBVWord :: (forall a. SBVWord a => BinOp a) -> Integer -> BinOp CWord
liftBinSBVWord op = liftBinCWord op op op op

liftUnSBVWord :: (forall a. SBVWord a => UnOp a) -> Integer -> UnOp CWord
liftUnSBVWord op = liftUnCWord op op op op

instance Mergeable CWord where
  symbolicMerge b sb = liftBinSBVWord
    (symbolicMerge b sb)
    (panic "CodeGen.SBVC.symbolicMerge @CWord" ["unused size argument was unexpectedly inspected"])


-- Primitives ------------------------------------------------------------------

type Value = GenValue SBool CWord

-- See also Cryptol.Symbolic.Prims.evalECon
--      and Cryptol.Prims.Eval.evalECon
evalECon :: ECon -> Value
evalECon e = case e of
  ECTrue        -> VBit true
  ECFalse       -> VBit false
  ECDemote      -> Eval.ecDemoteGeneric "CodeGen.SBVC.evalECon" mkCWord
  ECPlus        -> binArith "+" (+)
  ECMinus       -> binArith "-" (-)
  ECMul         -> binArith "*" (*)
  ECDiv         -> binArith "div" sDiv
  ECMod         -> binArith "mod" sMod
  {-
  ECExp         ->
  ECLg2         ->
  -}
  ECNeg         -> unArith "neg" negate
  ECLt          -> Eval.binary $ Eval.cmpOrder  lt
  ECGt          -> Eval.binary $ Eval.cmpOrder  gt
  ECLtEq        -> Eval.binary $ Eval.cmpOrder ngt
  ECGtEq        -> Eval.binary $ Eval.cmpOrder nlt
  ECEq          -> Eval.binary $ Eval.cmpOrder  eq
  ECNotEq       -> Eval.binary $ Eval.cmpOrder neq
  ECFunEq       -> Eval.funCmp  eq
  ECFunNotEq    -> Eval.funCmp neq
  ECMin         -> Eval.binary $ Eval.withOrder ngt
  ECMax         -> Eval.binary $ Eval.withOrder nlt
  ECAnd         -> Eval.binary $ Eval.pointwiseBinary (&&&) (liftBinSBVWord (.&.))
  ECOr          -> Eval.binary $ Eval.pointwiseBinary (|||) (liftBinSBVWord (.|.))
  ECXor         -> Eval.binary $ Eval.pointwiseBinary (<+>) (liftBinSBVWord  xor )
  ECCompl       -> Eval.unary  $ Eval.pointwiseUnary  bnot  (liftUnSBVWord complement)
  {-
  ECZero        ->
  ECShiftL      ->
  ECShiftR      ->
  ECRotL        ->
  ECRotR        ->
  ECCat         ->
  ECSplitAt     ->
  ECJoin        ->
  ECSplit       ->
  ECReverse     ->
  ECTranspose   ->
  ECAt          ->
  ECAtRange     ->
  ECAtBack      ->
  ECAtRangeBack ->
  ECFromThen    ->
  ECFromTo      ->
  ECFromThenTo  ->
  ECInfFrom     ->
  ECInfFromThen ->
  ECError       ->
  ECPMul        ->
  ECPDiv        ->
  ECPMod        ->
  ECRandom      ->
  -}
  _ -> panic "CodeGen.SBVC.evalECon" ["operation not supported: " ++ show e]

binArith :: String -> (forall a. SBVWord a => BinOp a) -> Value
binArith opName op = Eval.binary $ Eval.pointwiseBinary
  (panic "CodeGen.SBVC.evalECon"
    ["Bits were a complete surprise when evaluating " ++ opName])
  (liftBinSBVWord op)

unArith :: String -> (forall a. SBVWord a => UnOp a) -> Value
unArith opName op = Eval.unary $ Eval.pointwiseUnary
  (panic "CodeGen.SBVC.evalECon"
    ["Bits were a complete surprise when evaluating " ++ opName])
  (liftUnSBVWord op)


-- Environments ----------------------------------------------------------------

-- | Invariant: the uninterpreted names are a subset of the local names.
data Env = Env
  { envLocal         :: Map QName Value  -- ^ global declarations which should be inlined + things that are in a local scope
  , envUninterpreted :: Map QName Schema -- ^ declarations which should not be inlined
  , envTypes         :: Map TVar TValue
  }

instance Monoid Env where
  mempty = Env mempty mempty mempty
  mappend e e' = Env (mappend (envLocal         e) (envLocal         e'))
                     (mappend (envUninterpreted e) (envUninterpreted e'))
                     (mappend (envTypes         e) (envTypes         e'))

bindLocalTerm :: QName -> Value -> Env -> Env
bindLocalTerm n v e = e { envLocal = M.insert n v (envLocal e) }

-- | Intended for internal use only, as it can violate the invariant that
-- uninterpreted names are a subset of local names.
bindUninterpretedTerm :: QName -> Schema -> Env -> Env
bindUninterpretedTerm n t e = e { envUninterpreted = M.insert n t (envUninterpreted e) }

bindGlobalTerm :: QName -> Value -> Schema -> Env -> Env
bindGlobalTerm n v t = bindLocalTerm n v . bindUninterpretedTerm n t

bindType :: TVar -> TValue -> Env -> Env
bindType n v e = e { envTypes = M.insert n v (envTypes e) }

lookupLocalTerm :: QName -> Env -> Maybe Value
lookupLocalTerm n e = M.lookup n (envLocal e)

-- | Intended for internal use only (but not dangerous).
lookupUninterpretedTerm :: QName -> Env -> Maybe Value
lookupUninterpretedTerm n e = do
  t <- M.lookup n (envUninterpreted e)
  Nothing -- TODO: manufacture uninterpreted values for suitably simple schemes

lookupGlobalTerm :: QName -> Env -> Maybe Value
lookupGlobalTerm n e = lookupUninterpretedTerm n e <|> lookupLocalTerm n e

lookupTerm :: QName -> Env -> Value
lookupTerm n e = case lookupGlobalTerm n e of
  Just v  -> v
  Nothing -> panic "CodeGen.SBVC.lookupTerm"
    [ "No term named " ++ show n ++ " in scope" ]


-- Evaluation ------------------------------------------------------------------

evalExpr :: Env -> Expr -> Value
evalExpr = Eval.evalExprGeneric withSBVC

withSBVC :: ExprOperations Env SBool CWord
withSBVC = ExprOperations
  { eoECon       = evalECon
  , eoBindTerm   = bindLocalTerm
  , eoBindType   = bindType
  , eoLookupTerm = lookupTerm
  , eoEvalType   = evalType
  , eoListSel    = evalListSel
  , eoIf         = ite
  , eoPP         = pp
  }

evalType :: Env -> Type -> TValue
evalType env = Eval.evalType (mempty { Eval.envTypes = envTypes env })

evalListSel :: Int -> Value -> Value
evalListSel n (VWord cw) = VBit $ case cw of
  CWord8  w -> sbvTestBit w n
  CWord16 w -> sbvTestBit w n
  CWord32 w -> sbvTestBit w n
  CWord64 w -> sbvTestBit w n
  UnsupportedSize w -> panic "CodeGen.SBVC.evalListSel"
    [ "Trying to index into a word of unsupported size " ++ show w ]
evalListSel n (VSeq _  vs) = vs !! n
evalListSel n (VStream vs) = vs !! n
evalListSel _ v = panic "CodeGen.SBVC.evalListSel"
  [ "Trying to index into a non-list value:", pretty v ]


-- Pretty Printing -------------------------------------------------------------

-- TODO: use hex or WithBase instead, and reflect the bit widths visually
instance PP CWord where
  ppPrec _ cw = case cw of
    CWord8  w -> ppw 8  w
    CWord16 w -> ppw 16 w
    CWord32 w -> ppw 32 w
    CWord64 w -> ppw 64 w
    UnsupportedSize n -> size n
    where
    size n = text $ "<[" ++ show (n :: Int) ++ "]>"
    ppw  n = maybe (size n) (text . show) . unliteral

instance PP (WithBase Value) where
  ppPrec _ (WithBase opts val) = go val where
    go v = case v of
      VRecord fs   -> braces   (sep (punctuate comma (map ppField fs)))
      VTuple vals  -> parens   (sep (punctuate comma (map go    vals)))
      VSeq _ vals  -> brackets (sep (punctuate comma (map go    vals)))
      VBit b       -> ppSBVShow "<Bit>" b
      VWord w      -> pp w
      VStream vals -> brackets $ fsep
                               $ punctuate comma
                               ( take (useInfLength opts) (map go vals)
                                 ++ [text "..."]
                               )
      VFun _       -> text "<function>"
      VPoly _      -> text "<polymorphic value>"

    ppField (f,r) = pp f PP.<+> char '=' PP.<+> go r

instance PP Value where
  ppPrec n v = ppPrec n (WithBase defaultPPOpts v)

-- | Pretty-print literals as their values, and non-literals as some default
-- description (typically their type wrapped in angle brackets).
ppSBVLit :: SymWord a => Doc -> (a -> Doc) -> SBV a -> Doc
ppSBVLit sym lit expr = maybe sym lit (unliteral expr)

ppSBVShow :: (Show a, SymWord a) => String -> SBV a -> Doc
ppSBVShow sym = ppSBVLit (text sym) (text . show)


-- Code Generation -------------------------------------------------------------

dislocate :: P.Expr -> P.Expr
dislocate (P.ELocated v _) = dislocate v
dislocate v = v

location :: P.Expr -> Range
location (P.ELocated _ r) = r
location _ = emptyRange

class CName a where cName :: a -> String

instance CName Name where
  cName (Name s) = s
  cName (NewName pass n) = show pass ++ "_" ++ show n

instance CName QName where
  cName (QName (Just (ModName mods)) name) = intercalate "_" mods ++ "_" ++ cName name
  cName (QName Nothing name) = cName name

-- TODO:
-- * put module bindings in the environment
-- * handle pattern match failures
codeGen :: Maybe FilePath -> GenerationRoot -> (Module, ModuleEnv) -> IO ()
codeGen dir (Identifier id) (mod, modEnv) =
  case parseExpr id of
    Right e -> checkExpr e modEnv >>= \resT -> case resT of
      (Right ((e', schema), modEnv'), []) -> case defaultExpr (location e) e' schema of
        Just (subst, eMono) -> case apSubst subst schema of
          Forall [] [] t -> case eMono of
            EVar qn -> compileToC dir (cName qn) (supplyArgs eMono t)

pattern PSeq ty len = TCon (TC TCSeq) [ty, PNum len]
pattern PNum n = TCon (TC (TCNum n)) []
pattern PBit = TCon (TC TCBit) []
pattern i :-> o = TCon (TC TCFun) [i, o]
pattern PWord n = PSeq PBit n

-- TODO
supplyArgs :: Expr -> Type -> SBVCodeGen ()
supplyArgs = go . evalExpr mempty where
  go (VWord (CWord8 w)) (PWord 8) = cgOutput "out" w
  go (VFun f) (PWord 8 :-> t) = cgInput "in" >>= \w -> go (f (VWord (CWord8 w))) t