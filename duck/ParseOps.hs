-- Duck Operator Tree Parsing

module ParseOps (parseOps) where

-- Since the precedence of operators is adjustable, we parse expressions
-- involving operators in two passes.  This file contains the second pass.
-- Borrowed from http://hackage.haskell.org/trac/haskell-prime/attachment/wiki/FixityResolution/resolve.hs

import Var
import ParseMonad
import Pretty

import Data.Map (Map)
import qualified Data.Map as Map

parseOps :: (a -> Var -> a -> a) -> ([a],[Var]) -> P a
parseOps apply (args,ops) = do
  state <- get
  let prec = ps_prec state
  (e,[],[]) <- parse apply prec (-1) Nonfix (reverse args) (reverse ops)
  return e

parse :: (a -> Var -> a -> a) -> Map Var PrecFix -> Int -> Fixity -> [a] -> [Var] -> P (a, [Var], [a])
parse _ _ _ _ [e] _ = return (e, [], [])
parse apply prec p d (e:rest) ops@(op:ops')
  | p == p' && (d /= d' || d == Nonfix) = fail ("ambiguous infix expression at operator "++show (pretty op))
  | p > p' || p == p' && (d == Leftfix || d' == Nonfix) = return (e, ops, rest)
  | otherwise = do
    (e',ops'',rest') <- parse apply prec p' d' rest ops'
    parse apply prec p d (apply e op e' : rest') ops''
  where
  (p', d') = case Map.lookup op prec of
    Nothing -> (maxBound, Leftfix)
    Just f -> f
parse _ _ _ _ _ _ = undefined
