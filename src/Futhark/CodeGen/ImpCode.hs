{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE  GeneralizedNewtypeDeriving #-}
-- | Imperative intermediate language used as a stepping stone in code generation.
--
-- This is a generic representation parametrised on an extensible
-- arbitrary operation.
--
-- Originally inspired by the paper "Defunctionalizing Push Arrays"
-- (FHPC '14).
module Futhark.CodeGen.ImpCode
  ( Functions (..)
  , Function
  , FunctionT (..)
  , ValueDecl (..)
  , Param (..)
  , paramName
  , Size (..)
  , MemSize
  , DimSize
  , Type (..)
  , Space (..)
  , SpaceId
  , Code (..)
  , PrimValue (..)
  , ExpLeaf (..)
  , Exp
  , Volatility (..)
  , Arg (..)
  , var
  , index

    -- * Typed enumerations
  , Count (..)
  , Bytes
  , Elements
  , elements
  , bytes
  , withElemType

    -- * Converting from sizes
  , sizeToExp
  , dimSizeToExp
  , memSizeToExp

    -- * Analysis
  , functionsCalled

    -- * Re-exports from other modules.
  , module Language.Futhark.Core
  , module Futhark.Representation.Primitive
  , module Futhark.Analysis.PrimExp
  )
  where

import Control.Applicative
import Data.Monoid
import Data.List hiding (foldr)
import Data.Loc
import Data.Traversable
import Data.Foldable
import qualified Data.HashSet as HS

import Prelude hiding (foldr)

import Language.Futhark.Core
import Futhark.Representation.Primitive
import Futhark.Representation.AST.Syntax (Space(..), SpaceId)
import Futhark.Representation.AST.Attributes.Names
import Futhark.Representation.AST.Pretty ()
import Futhark.Util.IntegralExp
import Futhark.Analysis.PrimExp

import Futhark.Util.Pretty hiding (space)

data Size = ConstSize Int32
          | VarSize VName
          deriving (Eq, Show)

type MemSize = Size
type DimSize = Size

data Type = Scalar PrimType | Mem MemSize Space

data Param = MemParam VName DimSize Space
           | ScalarParam VName PrimType
             deriving (Show)

paramName :: Param -> VName
paramName (MemParam name _ _) = name
paramName (ScalarParam name _) = name

-- | A collection of imperative functions.
newtype Functions a = Functions [(Name, Function a)]

data ValueDecl = ArrayValue VName PrimType [DimSize]
               | ScalarValue PrimType VName
               deriving (Show)

-- | A imperative function, containing the body as well as its
-- low-level inputs and outouts, as well as its high-level arguments
-- and results.  The latter are only used if the function is an entry
-- point.
data FunctionT a = Function { functionEntry :: Bool
                            , functionOutput :: [Param]
                            , functionInput :: [Param]
                            , functionbBody :: Code a
                            , functionResult :: [ValueDecl]
                            , functionArgs :: [ValueDecl]
                            }
                 deriving (Show)

-- | Type alias for namespace control.
type Function = FunctionT

data Code a = Skip
            | Code a :>>: Code a
            | For VName Exp (Code a)
            | While Exp (Code a)
            | DeclareMem VName Space
            | DeclareScalar VName PrimType
            | Allocate VName (Count Bytes) Space
              -- ^ Memory space must match the corresponding
              -- 'DeclareMem'.
            | Copy VName (Count Bytes) Space VName (Count Bytes) Space (Count Bytes)
              -- ^ Destination, offset in destination, destination
              -- space, source, offset in source, offset space, number
              -- of bytes.
            | Write VName (Count Bytes) PrimType Space Volatility Exp
            | SetScalar VName Exp
            | SetMem VName VName Space
              -- ^ Must be in same space.
            | Call [VName] Name [Arg]
            | If Exp (Code a) (Code a)
            | Assert Exp SrcLoc
            | Comment String (Code a)
              -- ^ Has the same semantics as the contained code, but
              -- the comment should show up in generated code for ease
              -- of inspection.
            | Op a
            deriving (Show)

-- | The volatility of a memory access.
data Volatility = Volatile | Nonvolatile
                deriving (Eq, Ord, Show)

instance Monoid (Code a) where
  mempty = Skip
  Skip `mappend` y    = y
  x    `mappend` Skip = x
  x    `mappend` y    = x :>>: y

data ExpLeaf = ScalarVar VName
             | SizeOf PrimType
             | Index VName (Count Bytes) PrimType Space Volatility
           deriving (Eq, Show)

type Exp = PrimExp ExpLeaf

-- | A function call argument.
data Arg = ExpArg Exp
         | MemArg VName
         deriving (Show)

-- FIXME: At the moment, the Num instances (and family) assume that we
-- only operate on Int32 values.

-- | A wrapper around 'Imp.Exp' that maintains a unit as a phantom
-- type.
newtype Count u = Count { innerExp :: Exp }
                deriving (Eq, Show, Num, IntegralExp, FreeIn, Pretty)

-- | Phantom type for a count of elements.
data Elements

-- | Phantom type for a count of bytes.
data Bytes

elements :: Exp -> Count Elements
elements = Count

bytes :: Exp -> Count Bytes
bytes = Count

-- | Convert a count of elements into a count of bytes, given the
-- per-element size.
withElemType :: Count Elements -> PrimType -> Count Bytes
withElemType (Count e) t = bytes $ e * LeafExp (SizeOf t) (IntType Int32)

dimSizeToExp :: DimSize -> Count Elements
dimSizeToExp = elements . sizeToExp

memSizeToExp :: MemSize -> Count Bytes
memSizeToExp = bytes . sizeToExp

sizeToExp :: Size -> Exp
sizeToExp (VarSize v)   = LeafExp (ScalarVar v) (IntType Int32)
sizeToExp (ConstSize x) = ValueExp $ IntValue $ Int32Value $ fromIntegral x

var :: VName -> PrimType -> Exp
var = LeafExp . ScalarVar

index :: VName -> Count Bytes -> PrimType -> Space -> Volatility -> Exp
index arr i t s vol = LeafExp (Index arr i t s vol) t

-- Prettyprinting definitions.

instance Pretty op => Pretty (Functions op) where
  ppr (Functions funs) = stack $ intersperse mempty $ map ppFun funs
    where ppFun (name, fun) =
            text "Function " <> ppr name <> colon </> indent 2 (ppr fun)

instance Pretty op => Pretty (FunctionT op) where
  ppr (Function _ outs ins body results args) =
    text "Inputs:" </> block ins </>
    text "Outputs:" </> block outs </>
    text "Arguments:" </> block args </>
    text "Result:" </> block results </>
    text "Body:" </> indent 2 (ppr body)
    where block :: Pretty a => [a] -> Doc
          block = indent 2 . stack . map ppr

instance Pretty Param where
  ppr (ScalarParam name ptype) =
    ppr ptype <+> ppr name
  ppr (MemParam name size space) =
    text "mem" <> parens (ppr size) <> space' <+> ppr name
    where space' = case space of Space s      -> text "@" <> text s
                                 DefaultSpace -> mempty

instance Pretty ValueDecl where
  ppr (ScalarValue t name) =
    ppr t <+> ppr name
  ppr (ArrayValue mem et shape) =
    foldr f (ppr et) shape <+> text "at" <+> ppr mem
    where f e s = brackets $ s <> comma <> ppr e

instance Pretty Size where
  ppr (ConstSize x) = ppr x
  ppr (VarSize v)   = ppr v

instance Pretty op => Pretty (Code op) where
  ppr (Op op) = ppr op
  ppr Skip   = text "skip"
  ppr (c1 :>>: c2) = ppr c1 </> ppr c2
  ppr (For i limit body) =
    text "for" <+> ppr i <+> langle <+> ppr limit <+> text "{" </>
    indent 2 (ppr body) </>
    text "}"
  ppr (While cond body) =
    text "while" <+> ppr cond <+> text "{" </>
    indent 2 (ppr body) </>
    text "}"
  ppr (DeclareMem name space) =
    text "declare" <+> ppr name <+> text "as memory block" <> ppr space
  ppr (DeclareScalar name t) =
    text "declare" <+> ppr name <+> text "as scalar of type" <+> ppr t
  ppr (Allocate name e space) =
    ppr name <+> text "<-" <+> text "malloc" <> parens (ppr e) <> ppr space
  ppr (Write name i bt space vol val) =
    ppr name <> langle <> vol' <> ppr bt <> ppr space <> rangle <> brackets (ppr i) <+>
    text "<-" <+> ppr val
    where vol' = case vol of Volatile -> text "volatile "
                             Nonvolatile -> mempty
  ppr (SetScalar name val) =
    ppr name <+> text "<-" <+> ppr val
  ppr (SetMem dest from space) =
    ppr dest <+> text "<-" <+> ppr from <+> text "@" <> ppr space
  ppr (Assert e _) =
    text "assert" <> parens (ppr e)
  ppr (Copy dest destoffset destspace src srcoffset srcspace size) =
    text "memcpy" <>
    parens (ppMemLoc dest destoffset <> ppr destspace <> comma </>
            ppMemLoc src srcoffset <> ppr srcspace <> comma </>
            ppr size)
    where ppMemLoc base offset =
            ppr base <+> text "+" <+> ppr offset
  ppr (If cond tbranch fbranch) =
    text "if" <+> ppr cond <+> text "then {" </>
    indent 2 (ppr tbranch) </>
    text "} else {" </>
    indent 2 (ppr fbranch) </>
    text "}"
  ppr (Call dests fname args) =
    commasep (map ppr dests) <+> text "<-" <+>
    ppr fname <> parens (commasep $ map ppr args)
  ppr (Comment s code) =
    text "--" <+> text s </> ppr code

instance Pretty Arg where
  ppr (MemArg m) = ppr m
  ppr (ExpArg e) = ppr e

instance Pretty ExpLeaf where
  ppr (ScalarVar v) =
    ppr v
  ppr (Index v is bt space vol) =
    ppr v <> langle <> vol' <> ppr bt <> space' <> rangle <> brackets (ppr is)
    where space' = case space of DefaultSpace -> mempty
                                 Space s      -> text "@" <> text s
          vol' = case vol of Volatile -> text "volatile "
                             Nonvolatile -> mempty

  ppr (SizeOf t) =
    text "sizeof" <> parens (ppr t)

instance Functor Functions where
  fmap = fmapDefault

instance Foldable Functions where
  foldMap = foldMapDefault

instance Traversable Functions where
  traverse f (Functions funs) =
    Functions <$> traverse f' funs
    where f' (name, fun) = (name,) <$> traverse f fun

instance Functor FunctionT where
  fmap = fmapDefault

instance Foldable FunctionT where
  foldMap = foldMapDefault

instance Traversable FunctionT where
  traverse f (Function entry outs ins body results args) =
    Function entry outs ins <$> traverse f body <*> pure results <*> pure args

instance Functor Code where
  fmap = fmapDefault

instance Foldable Code where
  foldMap = foldMapDefault

instance Traversable Code where
  traverse f (x :>>: y) =
    (:>>:) <$> traverse f x <*> traverse f y
  traverse f (For i bound code) =
    For i bound <$> traverse f code
  traverse f (While cond code) =
    While cond <$> traverse f code
  traverse f (If cond x y) =
    If cond <$> traverse f x <*> traverse f y
  traverse f (Op kernel) =
    Op <$> f kernel
  traverse _ Skip =
    pure Skip
  traverse _ (DeclareMem name space) =
    pure $ DeclareMem name space
  traverse _ (DeclareScalar name bt) =
    pure $ DeclareScalar name bt
  traverse _ (Allocate name size s) =
    pure $ Allocate name size s
  traverse _ (Copy dest destoffset destspace src srcoffset srcspace size) =
    pure $ Copy dest destoffset destspace src srcoffset srcspace size
  traverse _ (Write name i bt val space vol) =
    pure $ Write name i bt val space vol
  traverse _ (SetScalar name val) =
    pure $ SetScalar name val
  traverse _ (SetMem dest from space) =
    pure $ SetMem dest from space
  traverse _ (Assert e loc) =
    pure $ Assert e loc
  traverse _ (Call dests fname args) =
    pure $ Call dests fname args
  traverse f (Comment s code) =
    Comment s <$> traverse f code

declaredIn :: Code a -> Names
declaredIn (DeclareMem name _) = HS.singleton name
declaredIn (DeclareScalar name _) = HS.singleton name
declaredIn (If _ t f) = declaredIn t <> declaredIn f
declaredIn (x :>>: y) = declaredIn x <> declaredIn y
declaredIn (For i _ body) = HS.singleton i <> declaredIn body
declaredIn (While _ body) = declaredIn body
declaredIn (Comment _ body) = declaredIn body
declaredIn _ = mempty

instance FreeIn a => FreeIn (Code a) where
  freeIn (x :>>: y) =
    freeIn x <> freeIn y `HS.difference` declaredIn x
  freeIn Skip =
    mempty
  freeIn (For i bound body) =
    i `HS.delete` (freeIn bound <> freeIn body)
  freeIn (While cond body) =
    freeIn cond <> freeIn body
  freeIn DeclareMem{} =
    mempty
  freeIn DeclareScalar{} =
    mempty
  freeIn (Allocate name size _) =
    freeIn name <> freeIn size
  freeIn (Copy dest x _ src y _ n) =
    freeIn dest <> freeIn x <> freeIn src <> freeIn y <> freeIn n
  freeIn (SetMem x y _) =
    freeIn x <> freeIn y
  freeIn (Write v i _ _ _ e) =
    freeIn v <> freeIn i <> freeIn e
  freeIn (SetScalar x y) =
    freeIn x <> freeIn y
  freeIn (Call dests _ args) =
    freeIn dests <> freeIn args
  freeIn (If cond t f) =
    freeIn cond <> freeIn t <> freeIn f
  freeIn (Assert e _) =
    freeIn e
  freeIn (Op op) =
    freeIn op
  freeIn (Comment _ code) =
    freeIn code

instance FreeIn ExpLeaf where
  freeIn (Index v e _ _ _) = freeIn v <> freeIn e
  freeIn (ScalarVar v) = freeIn v
  freeIn (SizeOf _) = mempty

instance FreeIn Arg where
  freeIn (MemArg m) = freeIn m
  freeIn (ExpArg e) = freeIn e

instance FreeIn Size where
  freeIn (VarSize name) = HS.singleton name
  freeIn (ConstSize _) = mempty

functionsCalled :: Code a -> HS.HashSet Name
functionsCalled (If _ t f) = functionsCalled t <> functionsCalled f
functionsCalled (x :>>: y) = functionsCalled x <> functionsCalled y
functionsCalled (For _ _ body) = functionsCalled body
functionsCalled (While _ body) = functionsCalled body
functionsCalled (Call _ fname _) = HS.singleton fname
functionsCalled _ = mempty
