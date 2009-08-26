{-# LANGUAGE PatternGuards, TypeSynonymInstances #-}
-- | Duck interpreter

-- For now, this is dynamically typed

module Interp 
  ( prog
  , main
  ) where

import Prelude hiding (lookup)
import Data.List hiding (lookup)
import qualified Data.List as List
import Data.Maybe
import Var
import Type
import Prims
import Value
import SrcLoc
import Pretty
import Lir hiding (prog)
import qualified Ptrie
import qualified Data.Map as Map
import Util
import ExecMonad
import Control.Monad hiding (guard)
import Control.Monad.Trans
import Data.Monoid
import qualified Infer
import qualified Base

-- Environments

-- Some aliases for documentation purposes
type Globals = Env
type Locals = Env

lookup :: Prog -> Globals -> Locals -> SrcLoc -> Var -> Exec TValue
lookup prog global env loc v
  | Just r <- Map.lookup v env = return r -- check for local definitions first
  | Just r <- Map.lookup v global = return r -- fall back to global definitions
  | Just o <- Map.lookup v (progOverloads prog) = return (
      ValClosure v [] o, -- if we find overloads, make a new closure
      tyClosure v [])
  | Just (o:_) <- Map.lookup v (progFunctions prog) = let tt = fst $ head $ overArgs o in return (
      ValClosure v [] (Ptrie.empty tt), -- this should never be used
      tyClosure v [])
  | Just _ <- Map.lookup v (progVariances prog) = return (ValType, tyType (TyCons v []))
  | otherwise = execError loc ("unbound variable " ++ qshow v)

-- Process a list of definitions into the global environment.
-- The global environment is threaded through function calls, so that
-- functions are allowed to refer to variables defined later on as long
-- as the variables are defined before the function is executed.
prog :: Prog -> Exec Globals
prog prog = foldM (definition prog) Map.empty (progDefinitions prog)

definition :: Prog -> Globals -> Definition -> Exec Globals
definition prog env (Def vl e) = withFrame (V $ intercalate "," $ map unV vars) [] (mconcat locs) $ do
  d <- expr prog env Map.empty noLoc e
  dl <- case (vl,d) of
          ([_],_) -> return [d]
          (_, (ValCons c dl, TyCons c' tl)) | istuple c, c == c', length vl == length dl, length vl == length tl -> return $ zip dl tl
          _ -> execError noLoc ("expected "++show (length vl)++"-tuple, got "++qshow d)
  return $ foldl (\g (v,d) -> Map.insert v d g) env (zip (map unLoc vl) dl)
  where (locs,vars) = unzipLoc vl

-- Perform a computation and then cast the result to a (more general) type.
-- For now, this cast is a nop on the data, but in future it may not be.
cast :: Prog -> Type -> Exec TValue -> Exec TValue
cast _ t x = do
  (d,_) <- x
  return (d,t)

expr :: Prog -> Globals -> Locals -> SrcLoc -> Exp -> Exec TValue
expr prog global env loc = exp where
  exp (Int i) = return $ (ValInt i, tyInt)
  exp (Chr i) = return $ (ValChr i, tyChr)
  exp (Var v) = lookup prog global env loc v
  exp (Apply e1 e2) = do
    v1 <- exp e1
    trans prog global env loc v1 e2
  exp (Let v e body) = do
    d <- exp e
    expr prog global (Map.insert v d env) loc body
  exp (Case _ [] Nothing) = execError loc ("pattern match failed: no cases")
  exp (Case e [] (Just (v,body))) = exp (Let v e body) -- equivalent to a let
  exp ce@(Case e pl def) = do
    t <- liftInfer prog $ Infer.expr prog (Map.map snd env) loc ce
    d <- exp e
    (c,dl,conses) <- case d of
      (v, TyCons tv types) -> do
        conses <- liftInfer prog $ Infer.lookupDatatype prog loc tv types
        case (v,conses) of
          (ValCons c dl,_) -> return (c,dl,conses)
          (ValType,[(Loc _ c,tl)]) -> return (c,map (const ValType) tl,conses)
          _ -> execError loc ("expected block, got "++qshow v)
      _ -> execError loc ("expected block, got "++qshow d)
    case find (\ (c',_,_) -> c == c') pl of
      Just (_,vl,e') ->
        if a == length dl then do
          let Just tl = Infer.lookupCons conses c
          cast prog t $ expr prog global (foldl (\s (v,d) -> Map.insert v d s) env (zip vl (zip dl tl))) loc e'
        else
          execError loc ("arity mismatch in pattern: "++qshow c++" expected "++show a++" argument"++(if a == 1 then "" else "s")
            ++" but got ["++intercalate "," (map pshow vl)++"]")
        where a = length vl
      Nothing -> case def of
        Nothing -> execError loc ("pattern match failed: exp = " ++ qshow d ++ ", cases = " ++ show pl) -- XXX data printed
        Just (v,e') -> cast prog t $ expr prog global (Map.insert v d env) loc e' 
  exp (Cons c el) = do
    (args,types) <- unzip =.< mapM exp el
    (tv,vl,tl) <- liftInfer prog $ Infer.lookupConstructor prog loc c
    result <- runMaybeT $ subsetList (typeInfo prog) types tl
    case result of
      Just (tenv,[]) -> return (ValCons c args, TyCons tv targs) where
        targs = map (\v -> Map.findWithDefault TyVoid v tenv) vl
      _ -> execError loc (qshow c++" expected arguments "++pshowlist tl++", got "++pshowlist args)
  exp (Prim op el) = do
    (dl,tl) <- unzip =.< mapM exp el
    d <- Base.prim loc op dl
    t <- liftInfer prog $ Base.primType loc op tl
    return (d,t)
  exp (Bind v e1 e2) = do
    d <- exp e1
    dt <- liftInfer prog $ Infer.runIO (snd d)
    t <- liftInfer prog $ Infer.expr prog (Map.insert v dt (Map.map snd env)) loc e2
    return (ValBindIO v d env e2, t)
  exp (Return e) = do
    (d,t) <- exp e
    return (ValLiftIO d, tyIO t)
  exp (PrimIO p el) = do
    (dl,tl) <- unzip =.< mapM exp el
    t <- liftInfer prog $ Base.primIOType loc p tl
    return (ValPrimIO p dl, tyIO t)
  exp (Spec e ts) = do
    (d,t) <- exp e
    result <- runMaybeT $ subset (typeInfo prog) t ts
    case result of
      Just (tenv,[]) -> return (d,substVoid tenv ts)
      Nothing -> execError loc (qshow e++" has type "++qshow t++", which is incompatible with type specification "++qshow ts)
      Just (_,leftovers) -> execError loc ("type specification "++qshow ts++" is invalid; can't overload on contravariant "++showContravariantVars leftovers)
  exp (ExpLoc l e) = expr prog global env l e

transExpr :: Locals -> Trans -> Exp -> Exec Value
transExpr env Delayed e = return $ ValDelay env e

trans :: Prog -> Globals -> Locals -> SrcLoc -> TValue -> Exp -> Exec TValue
trans prog global env loc f@(ValClosure _ _ ov, _) e
  | Left (Just tt) <- Ptrie.unPtrie ov = do
  t <- liftInfer prog $ Infer.expr prog (Map.map snd env) loc e
  a <- transExpr env tt e
  let at = (a, transType tt t)
  apply prog global f at t loc
trans prog global env loc f e = do
  a <- expr prog global env loc e
  apply prog global f a (snd a) loc

-- Because of the delay mechanism, we pass in two types related to the argument
-- "a".  The second type "at" is the type of the value which was passed in, and
-- is the type used for type inference/overload resolution.  The type inside
-- "a" is the type that will be seen inside the function.
apply :: Prog -> Globals -> TValue -> TValue -> Type -> SrcLoc -> Exec TValue
apply prog global (ValClosure f args ov, ft) a at loc = do
  let args' = args ++ [a]
  t <- liftInfer prog $ Infer.apply prog ft at loc
  case Ptrie.lookup [at] ov of
    Nothing -> execError loc ("unresolved overload: " ++ pshow f ++ " " ++ pshowlist (map snd args'))
    Just ov -> case Ptrie.unPtrie ov of
      Left _ -> return (ValClosure f args' ov, t)
      Right (Over _ _ _ _ Nothing) -> return (ValClosure f args' ov, t)
      Right (Over _ at _ vl (Just e)) -> cast prog t $ withFrame f args' loc $ expr prog global (Map.fromList $ zip vl $ zipWith ((.snd) .(,) .fst) args' at) loc e
apply prog global (ValDelay env e, ta) _ _ loc | Just (_,t) <- isTyArrow ta =
  cast prog t $ expr prog global env loc e
apply prog _ (_,t1) (_,t2) _ loc | Just (TyCons c tl) <- isTyType t1, Just t <- isTyType t2 =
  if length tl < length (Infer.lookupVariances prog c) then
    return (ValType, tyType (TyCons c (tl++[t])))
  else
    execError loc ("can't apply "++qshow t1++" to "++qshow t2++", "++qshow c++" is already fully applied")
apply _ _ (v1,t1) (v2,t2) _ loc = execError loc ("can't apply '"++pshow v1++" :: "++pshow t1++"' to '"++pshow v2++" :: "++pshow t2++"'")

typeInfo :: Prog -> TypeInfo (MaybeT Exec)
typeInfo prog = TypeInfo
  { typeApply = \t1 t2 -> mapMaybeT (liftInfer prog) (typeApply info t1 t2)
  , typeVariances = typeVariances info }
  where info = Infer.typeInfo prog

-- IO and main
main :: Prog -> Globals -> IO ()
main prog global = runExec $ do
  main <- lookup prog global Map.empty noLoc (V "main")
  _ <- runIO prog global main
  return ()

runIO :: Prog -> Globals -> TValue -> Exec TValue
runIO _ _ (ValLiftIO d, io) | Just t <- isTyIO io = return (d,t)
runIO prog global (ValPrimIO TestAll [], io) | Just t <- isTyIO io = testAll prog global >.= \d -> (d,t)
runIO _ _ (ValPrimIO p args, io) | Just t <- isTyIO io = Base.primIO p args >.= \d -> (d,t)
runIO prog global (ValBindIO v m env e, io) | Just t <- isTyIO io = do
  d <- runIO prog global m
  d' <- expr prog global (Map.insert v d env) noLoc e
  cast prog t $ runIO prog global d'
runIO _ _ d =
  execError noLoc ("expected IO computation, got "++qshow d)

testAll :: Prog -> Globals -> Exec Value
testAll prog global = do
  liftIO $ puts "running unit tests..."
  mapM_ test (Map.toList global)
  liftIO $ puts "success!"
  nop
  where
  test (V v,d)
    | isPrefixOf "test_" v = do
        liftIO $ puts ("  "++v)
        runIO prog global d
        success
    | otherwise = success
  nop = return $ ValCons (V "()") []

