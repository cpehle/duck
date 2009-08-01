{-# LANGUAGE PatternGuards #-}
-- | Duck Intermediate Representation

module Ir 
  ( Decl(..)
  , Exp(..)
  , Binop(..)
  , PrimIO(..)
  , prog
  , binopString
  ) where

import Var
import Type
import Data.Maybe
import qualified Ast
import qualified Data.Set as Set
import qualified Data.Map as Map

import Util
import Pretty
import ParseOps
import SrcLoc
import Text.PrettyPrint
import Data.List
import Data.Either
import Data.Function
import qualified Data.Foldable as Fold
import GHC.Exts
import Control.Monad hiding (guard)

data Decl
  = LetD Var Exp
  | LetM [Var] Exp
  | Over Var TypeSet Exp
  | Data CVar [Var] [(CVar, [TypeSet])]
  deriving Show

data Exp
  = Int Int
  | Var Var
  | Lambda Var Exp
  | Apply Exp Exp
  | Let Var Exp Exp
  | Cons CVar [Exp]
  | Case Exp [(CVar, [Var], Exp)] (Maybe (Var,Exp))
  | Binop Binop Exp Exp
  | Spec Exp TypeSet
  | ExpLoc SrcLoc Exp
    -- Monadic IO
  | Bind Var Exp Exp
  | Return Exp
  | PrimIO PrimIO [Exp]
  deriving Show

data Binop
  = IntAddOp
  | IntSubOp
  | IntMulOp
  | IntDivOp
  | IntEqOp
  | IntLessOp
  deriving Show

data PrimIO
  = ExitFailure
  | TestAll
  deriving Show

-- Ast to IR conversion

data Env = Env 
  { envPrecs :: PrecEnv
  }

prog_vars :: Ast.Prog -> InScopeSet
prog_vars = foldl' decl_vars Set.empty . map unLoc

decl_vars :: InScopeSet -> Ast.Decl -> InScopeSet
decl_vars s (Ast.SpecD v _) = Set.insert v s 
decl_vars s (Ast.DefD v _ _) = Set.insert v s 
decl_vars s (Ast.LetD p _) = pattern_vars s p
decl_vars s (Ast.Data _ _ _) = s
decl_vars s (Ast.Infix _ _) = s

pattern_vars :: InScopeSet -> Ast.Pattern -> InScopeSet
pattern_vars s Ast.PatAny = s
pattern_vars s (Ast.PatVar v) = Set.insert v s
pattern_vars s (Ast.PatCons _ pl) = foldl' pattern_vars s pl
pattern_vars s (Ast.PatOps o) = Fold.foldl' pattern_vars s o
pattern_vars s (Ast.PatList pl) = foldl' pattern_vars s pl
pattern_vars s (Ast.PatSpec p _) = pattern_vars s p
pattern_vars s (Ast.PatLoc _ p) = pattern_vars s p

prog_precs :: Ast.Prog -> PrecEnv
prog_precs = foldl' set_precs Map.empty where
  -- TODO: error on duplicates
  set_precs s (Loc _ (Ast.Infix p vl)) = foldl' (\s v -> Map.insert v p s) s vl
  set_precs s _ = s

prog :: [Loc Ast.Decl] -> IO [Decl]
prog p = either die return (decls p) where
  env = Env $ prog_precs p
  s = prog_vars p

  -- Declaration conversion can turn multiple Ast.Decls into a single Ir.Decl, as with
  --   f :: <type>
  --   f x = ...
  -- We use Either in order to return errors.  TODO: add location information to the errors.
  decls :: [Loc Ast.Decl] -> Either String [Decl]
  decls [] = return []
  decls (Loc _ (Ast.DefD f args body) : rest) = do
    e <- expr env s (Ast.Lambda args body)
    (LetD f e :) =.< decls rest
  decls (Loc _ (Ast.SpecD f t) : rest) = case rest of
    Loc _ (Ast.DefD f' args body) : rest | f == f' -> do
      e <- expr env s (Ast.Lambda args body)
      (Over f t e :) =.< decls rest
    Loc _ (Ast.DefD f' _ _) : _ -> Left ("Syntax error: type specification for '"++show (pretty f)++"' followed by definition of '"++show (pretty f')++"'") -- TODO: clean up error handling
    _ -> Left ("Syntax error: type specification for '"++show (pretty f)++"' must be followed by a definition") -- TODO: clean up error handling
  decls (Loc _ (Ast.LetD Ast.PatAny e) : rest) = do
    e <- expr env s e
    (LetD ignored e :) =.< decls rest
  decls (Loc _ (Ast.LetD (Ast.PatVar v) e) : rest) = do
    e <- expr env s e
    (LetD v e :) =.< decls rest
  decls (Loc _ (Ast.LetD p e) : rest) = do
    e <- expr env s e
    let d = case vars of
              [v] -> LetD v (m e (Var v))
              vl -> LetM vl (m e (Cons (tupleCons vars) (map Var vars)))
    (d :) =.< decls rest
    where
    vars = Set.toList (pattern_vars Set.empty p)
    (_,_,m) = match env s p
  decls (Loc _ (Ast.Data t args cons) : rest) = (Data t args cons :) =.< decls rest
  decls (Loc _ (Ast.Infix _ _) : rest) = decls rest

expr :: Env -> InScopeSet -> Ast.Exp -> Either String Exp
expr _ _ (Ast.Int i) = return $ Int i
expr _ _ (Ast.Var v) = return $ Var v
expr env s (Ast.Lambda pl e) = expr env s' e >.= \e -> foldr Lambda (m (map Var vl) e) vl where
  (vl, s', m) = matches env s pl
expr env s (Ast.Apply f args) =do
  f <- expr env s f
  args <- mapM (expr env s) args
  return $ foldl' Apply f args
expr env s (Ast.Let p e c) = do
  e <- expr env s e
  c <- expr env s' c
  return $ m e c
  where
  (_,s',m) = match env s p
expr env s (Ast.Def f args body c) = do
  body <- expr env s' body
  c <- expr env sc c
  return $ Let f (foldr Lambda (m (map Var vl) body) vl) c
  where
  (vl, s', m) = matches env s args
  sc = Set.insert f s
expr env s (Ast.Case e cl) = expr env s e >>= \e -> cases env s e cl
expr env s (Ast.Ops o) = expr env s $ Ast.opsExp $ sortOps (envPrecs env) o
expr env s (Ast.Spec e t) = expr env s e >.= \e -> Spec e t
expr env s (Ast.List el) = foldr (\a b -> Cons (V ":") [a,b]) (Cons (V "[]") []) =.< mapM (expr env s) el
expr env s (Ast.If c e1 e2) = do
  c <- expr env s c
  e1 <- expr env s e1
  e2 <- expr env s e2
  return $ Apply (Apply (Apply (Var (V "if")) c) e1) e2
expr env s (Ast.ExpLoc l e) = ExpLoc l =.< expr env s e
expr _ _ Ast.Any = Left "'_' not allowed in expressions"

-- |match processes a single pattern into an input variable, a new in-scope set,
-- and a transformer that converts an input expression and a result expression
-- into new expression representing the match
match :: Env -> InScopeSet -> Ast.Pattern -> (Var, InScopeSet, Exp -> Exp -> Exp)
match _ s Ast.PatAny = (ignored, s, match_helper ignored)
match _ s (Ast.PatVar v) = (v, Set.insert v s, match_helper v)
match env s (Ast.PatSpec p _) = match env s p
match env s (Ast.PatLoc _ p) = match env s p
match env s (Ast.PatOps o) = match env s $ Ast.opsPattern $ sortOps (envPrecs env) o
match env s (Ast.PatCons c args) = (x, s', m) where
  x = fresh s
  (vl, s', ms) = matches env s args
  m em er = Case em [(c, vl, ms (map Var vl) er)] Nothing
match env s (Ast.PatList pl) = match env s (patternList pl)

match_helper v em er = case em of
  Var v' | v == v' -> er
  _ -> Let v em er

-- in spirit, matches = fold match
matches :: Env -> InScopeSet -> [Ast.Pattern] -> ([Var], InScopeSet, [Exp] -> Exp -> Exp)
matches env s pl = foldr f ([],s,\[] -> id) pl where
  f p (vl,s,m) = (v:vl, s', \ (e:el) -> m' e . m el) where
    (v,s',m') = match env s p

-- |cases turns a multilevel pattern match into iterated single level pattern match by
--   (1) partitioning the cases by outer element,
--   (2) performing the outer match, and
--   (3) iteratively matching the components returned in the outer match
-- Part (3) is handled by building up a stack of unprocessed expressions and an associated
-- set of pattern stacks, and then iteratively reducing the set of possibilities.
cases :: Env -> InScopeSet -> Exp -> [(Ast.Pattern, Ast.Exp)] -> Either String Exp
cases env s e arms = reduce s [e] (map (\ (p,e) -> p :. Base e) arms) where 

  -- reduce takes n unmatched expressions and a list of n-tuples (lists) of patterns, and
  -- iteratively reduces the list of possibilities by matching each expression in turn.  This is
  -- used to process the stack of unmatched patterns that build up as we expand constructors.
  reduce :: InScopeSet -> [Exp] -> [Stack Ast.Pattern Ast.Exp] -> Either String Exp
  reduce s [] (Base e:_) = expr env s e -- no more patterns to match, so just pick the first possibility
  reduce _ [] _ = undefined -- there will always be at least one possibility, so this never happens
  reduce s (e:rest) alts = return (Case e) `ap` mapM cons groups `ap` fallback where

    -- group alternatives by toplevel tag (along with arity)
    -- note: In future, the arity might be looked up in an environment
    -- (or maybe not, if constructors are overloaded based on arity?)
    groups = groupPairs conses
    (conses,others) = partitionEithers (map separate alts)

    -- cons processes each case of the toplevel match
    -- If only one alternative remains, we break out of the 'reduce' recursion and switch
    -- to 'matches', which avoids trivial matches of the form "case v of v -> ..."
    cons :: ((Var,Int),[Stack Ast.Pattern Ast.Exp]) -> Either String (Var,[Var],Exp)
    cons ((c,arity),alts') = case alts' of
      [alt] -> expr env s' e >.= \e -> (c,vl',m ex e) where -- single alternative, use matches
        (pl,e) = splitStack alt
        (vl,s',m) = matches env s pl
        vl' = take arity vl
        ex = (map Var vl') ++ rest
      _ -> ex >.= \ex -> (c,vl,ex) where -- many alernatives, use reduce
        (s',vl) = freshVars s arity
        ex = reduce s' (map Var vl ++ rest) alts'

    fallback :: Either String (Maybe (Var,Exp))
    fallback = case others of
      [] -> return Nothing
      (v,e):_ -> reduce (Set.insert v s) rest [e] >.= \ex -> Just (v,ex)

  -- peel off the outer level of the first pattern, and separate into conses and defaults
  separate :: Stack Ast.Pattern Ast.Exp -> Either ((Var,Int), Stack Ast.Pattern Ast.Exp) (Var, Stack Ast.Pattern Ast.Exp)
  separate (Ast.PatAny :. e) = Right (ignored,e)
  separate (Ast.PatVar v :. e) = Right (v,e)
  separate (Ast.PatSpec p _ :. e) = separate (p:.e)
  separate (Ast.PatLoc _ p :. e) = separate (p:.e)
  separate (Ast.PatOps o :. e) = separate ((Ast.opsPattern $ sortOps (envPrecs env) o) :. e)
  separate (Ast.PatCons c pl :. e) = Left ((c, length pl), pl++.e)
  separate (Ast.PatList pl :. e) = separate (patternList pl :. e)
  separate (Base _) = undefined -- will never happen, since here the stack is nonempty

patternList :: [Ast.Pattern] -> Ast.Pattern
patternList [] = Ast.PatCons (V "[]") []
patternList (p:pl) = Ast.PatCons (V ":") [p, patternList pl]

-- Pretty printing

instance Pretty Decl where
  pretty (LetD v e) =
    pretty v <+> equals <+> nest 2 (pretty e)
  pretty (LetM vl e) =
    hcat (intersperse (text ", ") (map pretty vl)) <+> equals <+> nest 2 (pretty e)
  pretty (Over v t e) =
    pretty v <+> text "::" <+> pretty t $$
    pretty v <+> equals <+> nest 2 (pretty e)
  pretty (Data t args cons) =
    pretty (Ast.Data t args cons)

instance Pretty Exp where
  pretty' (Spec e t) = (0, guard 1 e <+> text "::" <+> guard 60 t)
  pretty' (Let v e body) = (0,
    text "let" <+> pretty v <+> equals <+> guard 0 e <+> text "in"
      $$ guard 0 body)
  pretty' (Case e pl d) = (0,
    text "case" <+> pretty e <+> text "of" $$
    vjoin '|' (map arm pl ++ def d)) where
    arm (c, vl, e) 
      | istuple c = hcat (intersperse (text ", ") pvl) <+> end
      | otherwise = pretty c <+> sep pvl <+> end
      where pvl = map pretty vl
            end = text "->" <+> pretty e
    def Nothing = []
    def (Just (v, e)) = [pretty v <+> text "->" <+> pretty e]
  pretty' (Int i) = pretty' i
  pretty' (Var v) = pretty' v
  pretty' (Lambda v e) = (1, pretty v <+> text "->" <+> nest 2 (guard 1 e))
  pretty' (Apply e1 e2) = case (apply e1 [e2]) of
    (Var v, [e1,e2]) | Just prec <- precedence v -> (prec,
      let V s = v in
      (guard prec e1) <+> text s <+> (guard (prec+1) e2))
    (Var c, el) | Just n <- tuplelen c, n == length el -> (1,
      hcat $ intersperse (text ", ") $ map (guard 2) el)
    (e, el) -> (50, guard 50 e <+> prettylist el)
    where apply (Apply e a) al = apply e (a:al) 
          apply e al = (e,al)
  pretty' (Cons (V ":") [h,t]) | Just t' <- extract t = (100,
    brackets (hcat (intersperse (text ", ") $ map (guard 2) (h : t')))) where
    extract (Cons (V "[]") []) = Just []
    extract (Cons (V ":") [h,t]) = (h :) =.< extract t
    extract _ = Nothing
  pretty' (Cons c args) | istuple c = (1,
    hcat $ intersperse (text ", ") $ map (guard 2) args)
  pretty' (Cons c args) = (50, pretty c <+> sep (map (guard 51) args))
  pretty' (Binop op e1 e2) | prec <- binopPrecedence op = (prec,
    guard prec e1 <+> text (binopString op) <+> guard prec e2)
  pretty' (Bind v e1 e2) = (6,
    pretty v <+> text "<-" <+> guard 0 e1 $$ guard 0 e2)
  pretty' (Return e) = (6, text "return" <+> guard 7 e)
  pretty' (PrimIO p []) = pretty' p
  pretty' (PrimIO p args) = (50, guard 50 p <+> prettylist args)
  pretty' (ExpLoc _ e) = pretty' e
  -- pretty' (ExpLoc l e) = fmap (text "{-@" <+> text (show l) <+> text "-}" <+>) $ pretty' e

instance Pretty PrimIO where
  pretty' p = (100, text (show p))

binopPrecedence :: Binop -> Int
binopPrecedence op = case op of
  IntAddOp -> 20
  IntSubOp -> 20
  IntMulOp -> 30
  IntDivOp -> 30
  IntEqOp -> 10
  IntLessOp -> 10

binopString :: Binop -> String
binopString op = case op of
  IntAddOp -> "+"
  IntSubOp -> "-"
  IntMulOp -> "*"
  IntDivOp -> "/"
  IntEqOp -> "=="
  IntLessOp -> "<"
