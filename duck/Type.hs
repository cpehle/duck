{-# LANGUAGE PatternGuards, MultiParamTypeClasses, FunctionalDependencies, UndecidableInstances, FlexibleInstances, TypeSynonymInstances, StandaloneDeriving #-}
{-# OPTIONS -fno-warn-orphans #-}
-- | Duck Types

module Type
  ( TypeVal(..)
  , TypePat(..)
  , TypeFun(..)
  , IsType(..)
  , TypeEnv
  , Variance(..)
  , substVoid
  , singleton
  , unsingleton, unsingleton'
  , freeVars
  , generalType
  -- * Transformation annotations
  , Trans(..), TransType
  , argType
  -- * Datatypes
  , Datatype(..), Datatypes
  , dataName, dataLoc, dataTyVars, dataConses, dataVariances
  ) where

import Data.Map (Map)
import qualified Data.Map as Map

import Util
import Pretty
import Var
import SrcLoc

-- Pull in autogenerated code
import Gen.Type

-- Add instance declarations
deriving instance Eq t => Eq (TypeFun t)
deriving instance Ord t => Ord (TypeFun t)
deriving instance Show t => Show (TypeFun t)
deriving instance Eq TypeVal
deriving instance Ord TypeVal
deriving instance Show TypeVal
deriving instance Eq TypePat
deriving instance Ord TypePat
deriving instance Show TypePat
deriving instance Eq Trans
deriving instance Ord Trans
deriving instance Show Trans

type TypeEnv = Map Var TypeVal
type TransType t = (Trans, t)

instance HasVar TypePat where
  var = TsVar
  unVar (TsVar v) = Just v
  unVar _ = Nothing

class IsType t where
  typeCons :: CVar -> [t] -> t
  typeFun :: [TypeFun t] -> t
  typeVoid :: t

  unTypeCons :: t -> Maybe (CVar, [t])
  unTypeFun :: t -> Maybe [TypeFun t]

  typePat :: t -> TypePat

instance IsType TypeVal where
  typeCons = TyCons
  typeFun = TyFun
  typeVoid = TyVoid

  unTypeCons (TyCons c a) = Just (c,a)
  unTypeCons _ = Nothing
  unTypeFun (TyFun f) = Just f
  unTypeFun _ = Nothing

  typePat = singleton

instance IsType TypePat where
  typeCons = TsCons
  typeFun = TsFun
  typeVoid = TsVoid

  unTypeCons (TsCons c a) = Just (c,a)
  unTypeCons _ = Nothing
  unTypeFun (TsFun f) = Just f
  unTypeFun _ = Nothing

  typePat = id

-- |See definition of Datatype in type.duck
dataName :: Datatype -> CVar
dataName (Data v _ _ _ _) = v
dataLoc :: Datatype -> SrcLoc
dataLoc (Data _ l _ _ _) = l
dataTyVars :: Datatype -> [Var]
dataTyVars (Data _ _ vl _ _) = vl
dataConses :: Datatype -> [(Loc CVar, [TypePat])]
dataConses (Data _ _ _ cl _) = cl
dataVariances :: Datatype -> [Variance]
dataVariances (Data _ _ _ _ vl) = vl
instance HasLoc Datatype where loc = dataLoc
type Datatypes = Map CVar Datatype

-- |Type environment substitution
subst :: TypeEnv -> TypePat -> TypePat
subst env (TsVar v)
  | Just t <- Map.lookup v env = singleton t
  | otherwise = TsVar v
subst env (TsCons c tl) = TsCons c (map (subst env) tl)
subst env (TsFun f) = TsFun (map fun f) where
  fun (FunArrow s t) = FunArrow (subst env s) (subst env t)
  fun (FunClosure f tl) = FunClosure f (map (subst env) tl)
subst _ TsVoid = TsVoid
_subst = subst

-- |Type environment substitution with unbound type variables defaulting to void
substVoid :: TypeEnv -> TypePat -> TypeVal
substVoid env (TsVar v) = Map.findWithDefault TyVoid v env
substVoid env (TsCons c tl) = TyCons c (map (substVoid env) tl)
substVoid env (TsFun f) = TyFun (map fun f) where
  fun (FunArrow s t) = FunArrow (substVoid env s) (substVoid env t)
  fun (FunClosure f tl) = FunClosure f (map (substVoid env) tl)
substVoid _ TsVoid = TyVoid

-- |Occurs check
occurs :: TypeEnv -> Var -> TypePat -> Bool
occurs env v (TsVar v') | Just t <- Map.lookup v' env = occurs' v t
occurs _ v (TsVar v') = v == v'
occurs env v (TsCons _ tl) = any (occurs env v) tl
occurs env v (TsFun f) = any fun f where
  fun (FunArrow s t) = occurs env v s || occurs env v t
  fun (FunClosure _ tl) = any (occurs env v) tl
occurs _ _ TsVoid = False
_occurs = occurs

-- |Types contains no variables
occurs' :: Var -> TypeVal -> Bool
occurs' _ _ = False

-- |This way is easy
--
-- For convenience, we overload the singleton function a lot.
class Singleton a b | a -> b where
  singleton :: a -> b

instance Singleton TypeVal TypePat where
  singleton (TyCons c tl) = TsCons c (singleton tl)
  singleton (TyFun f) = TsFun (singleton f)
  singleton TyVoid = TsVoid

instance Singleton a b => Singleton [a] [b] where
  singleton = map singleton

instance Singleton a b => Singleton (TypeFun a) (TypeFun b) where
  singleton (FunArrow s t) = FunArrow (singleton s) (singleton t)
  singleton (FunClosure f tl) = FunClosure f (singleton tl)
 
-- TODO: I'm being extremely cavalier here and pretending that the space of
-- variables in TsCons and TsVar is disjoint.  When this fails in the future,
-- skolemize will need to be fixed to turn TsVar variables into fresh TyCons
-- variables.
_ignore = skolemize
skolemize :: TypePat -> TypeVal
skolemize (TsVar v) = TyCons v [] -- skolemization
skolemize (TsCons c tl) = TyCons c (map skolemize tl)
skolemize (TsFun f) = TyFun (map skolemizeFun f)
skolemize TsVoid = TyVoid

skolemizeFun :: TypeFun TypePat -> TypeFun TypeVal
skolemizeFun (FunArrow s t) = FunArrow (skolemize s) (skolemize t)
skolemizeFun (FunClosure f tl) = FunClosure f (map skolemize tl)

-- |Convert a singleton typeset to a type if possible
unsingleton :: TypePat -> Maybe TypeVal
unsingleton = unsingleton' Map.empty

unsingleton' :: TypeEnv -> TypePat -> Maybe TypeVal
unsingleton' env (TsVar v) | Just t <- Map.lookup v env = Just t
unsingleton' _ (TsVar _) = Nothing
unsingleton' env (TsCons c tl) = TyCons c =.< mapM (unsingleton' env) tl
unsingleton' env (TsFun f) = TyFun =.< mapM (unsingletonFun' env) f
unsingleton' _ TsVoid = Just TyVoid

unsingletonFun' :: TypeEnv -> TypeFun TypePat -> Maybe (TypeFun TypeVal)
unsingletonFun' env (FunArrow s t) = do
  s <- unsingleton' env s
  t <- unsingleton' env t
  return (FunArrow s t)
unsingletonFun' env (FunClosure f tl) = FunClosure f =.< mapM (unsingleton' env) tl

-- |Find the set of free variables in a typeset
freeVars :: TypePat -> [Var]
freeVars (TsVar v) = [v]
freeVars (TsCons _ tl) = concatMap freeVars tl
freeVars (TsFun fl) = concatMap f fl where
  f (FunArrow s t) = freeVars s ++ freeVars t
  f (FunClosure _ tl) = concatMap freeVars tl
freeVars TsVoid = []

-- |Converts an annotation argument type to the effective type of the argument within the function.
argType :: IsType t => TransType t -> t
argType (NoTrans, t) = t
argType (Delayed, t) = typeFun [FunArrow (typeCons (V "()") []) t]

generalType :: [a] -> ([TypePat], TypePat)
generalType vl = (tl,r) where
  r : tl = map TsVar (take (length vl + 1) standardVars)

-- Pretty printing

instance Pretty TypePat where
  pretty' (TsVar v) = pretty' v
  pretty' (TsCons t []) = pretty' t
  pretty' (TsCons t tl) | isTuple t = 3 #> punctuate ',' tl
  pretty' (TsCons t tl) = prettyap t tl
  pretty' (TsFun f) = pretty' f
  pretty' TsVoid = pretty' "Void"

instance Pretty TypeVal where
  pretty' = pretty' . singleton

instance Pretty t => Pretty (TypeFun t) where
  pretty' (FunClosure f []) = pretty' f
  pretty' (FunClosure f tl) = prettyap f tl
  pretty' (FunArrow s t) = 1 #> s <+> "->" <+> guard 1 t

instance Pretty t => Pretty [TypeFun t] where
  pretty' [f] = pretty' f
  pretty' fl = 5 #> punctuate '&' fl

instance (Pretty t, IsType t) => Pretty (TransType t) where
  pretty' (NoTrans, t) = pretty' t
  pretty' (c, t) = prettyap (show c) [t]
