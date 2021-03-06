{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}
-- | Duck Abstract Syntax Tree
--
-- The parser ("Parse") turns the string contents of a single file into a 'Prog'

module Ast
  ( Prog
  , Decl(..)
  , DataCon, DataField(..)
  , Exp(..)
  , Stmt(..)
  , Pattern(..)
  , Switch, Case(..), CaseTail(..)
  , imports
  , opsExp
  , opsPattern
  , expTypeDesc, patTypeDesc
  ) where

import Data.Maybe

import Pretty
import SrcLoc
import Var
import Stage
import ParseOps
import IrType

-- |An entire file is just a list of top-level declarations, where the locations refer to the whole declaration, body and all
type Prog = [Loc Decl]

-- |Top-level declaration
data Decl
  = SpecD !(Loc Var) !TypePat           -- ^ Type declaration (for overloads): @VAR :: TYPE@
  | DefD !(Loc Var) [Pattern] Exp       -- ^ Function definition with arguments: @VAR PATs = EXP@
  | ExpD Exp                            -- ^ Top level expression: @EXP@
  | LetD !Pattern Exp                   -- ^ Global definition without arguments: @PAT = EXP@
  | Data !(Loc CVar) [Var] [DataCon]    -- ^ Datatype declaration: @data CVAR VARs = { CVAR TYPEs ; ... }@
  | Infix !PrecFix [Var]                -- ^ Fixity declaration: @infix[lr] PREC VARs@
  | Import !Var                         -- ^ Import directive: @import VAR@
  deriving Show

-- |One constructor in a data definition
type DataCon = (Loc CVar, [DataField])
-- |One field in a data constructor
data DataField = DataField 
  { fieldName :: Maybe (Loc Var)
  , fieldType :: TypePat
  } deriving Show

-- |Expression.
-- Patterns and types are also parsed into these before being converted to 'Pattern' or 'TypePat' in "Parse"
data Exp
  = Def !Var [Pattern] Exp Exp          -- ^ Local function definition with arguments: @let VAR PATs = EXP in EXP@ (equivalent to @DoSeq [StmtDef VAR PATs EXP, EXP]@)
  | Let !Bool !Pattern Exp Exp          -- ^ Local variable definition: @let PAT = EXP in EXP@ (equivalent to @DoSeq [StmtLet PAT EXP, EXP]@)
  | Lambda [Pattern] Exp                -- ^ @PAT1 -> PAT2 ... -> EXP@
  | Apply Exp [Exp]                     -- ^ Application: @EXP EXPs@
  | Var !Var
  | Int !Int
  | Char !Char
  | String !String
  | Any                                 -- ^ Magic underscore variable: @_@
  | List [Exp]                          -- ^ List: @[EXP1,...]@
  | Ops !(Ops Exp)
  | Equals !Var Exp                     -- ^ @(VAR = EXP)@, only for PatAs
  | Spec Exp !TypePat                   -- ^ Type specification: @EXP :: TYPE@
  | Case !Bool [Switch]                 -- ^ Case group
  | If !Bool Exp Exp Exp                -- ^ @if EXP then EXP else EXP@
  | Seq [Loc Stmt]                      -- ^ Expression sequence: @{ STMT ; ... }@
  | ExpLoc SrcLoc !Exp                  -- ^ Meta source location information, inserted at almost every level
  deriving Show

type Switch = (Exp, Case)

-- |Case line.
-- Case groups can contain pattern matches and guards, in arbitrary combinations.
data Case
  = CaseMatch [(Pattern,CaseTail)]      -- ^ succeed if expression matches pattern: @case EXP of { PAT CASE ; ... }@
  | CaseGuard CaseTail                  -- ^ succeed if expression True, or fail: @case EXP CASE@ (equivalent to @CaseMatch EXP [(True,CASE)]@)
  deriving Show

-- |Case action.
-- What to do if everything so far has suceeded.
data CaseTail
  = CaseGroup !Bool [Switch]            -- ^ Check cases sequentially, or fail
  | CaseBody Exp                        -- ^ Succeed and execute
  deriving Show

-- |Statement.
-- Statements are thins that can be in a "do" expression block.
data Stmt
  = StmtExp Exp                         -- ^ Simple expression, either to return (if last) or presumably with effect
  | StmtLet Pattern Exp                 -- ^ Variable definition: @PAT = EXP@
  | StmtDef Var [Pattern] Exp           -- ^ Function definition: @VAR PATs = EXP@
  -- StmtSpec ?
  deriving Show

-- |Pattern.
-- For the most part, each constructor here is converted from its non-Pat equivalent in 'Exp'.
data Pattern
  = PatAny
  | PatVar !Var
  | PatInt !Int
  | PatChar !Char
  | PatString !String
  | PatCons !CVar [Pattern]
  | PatList [Pattern]
  | PatOps !(Ops Pattern)
  | PatLambda [Pattern] !Pattern
  | PatAs !Var !Pattern
  | PatSpec !Pattern !TypePat
  | PatTrans !Var !Pattern
  | PatLoc SrcLoc !Pattern
  deriving Show

-- |List of 'Import' directives
imports :: Prog -> [String]
imports = mapMaybe imp where
  imp (L _ (Import (V v))) = Just v
  imp _ = Nothing

-- |Convert an 'Ops' expression into its 'Apply' equivalents, without applying any precedences (see "ParseOps")
opsExp :: SrcLoc -> Ops Exp -> Exp
opsExp _ (OpAtom a) = a
opsExp loc (OpUn (V "-") a) = Apply (Var (V "negate")) [opsExp loc a]
opsExp loc (OpUn op _) = fatal $ stageMsg StageParse loc $ quoted op <+> "cannot be used as a prefix operator (the only valid prefix operator is" <+> quoted "-" <> ")"
opsExp loc (OpBin o l r) = Apply (Var o) [opsExp loc l, opsExp loc r]

-- |Convert 'PatOps' pattern into its 'PatCons' equivalents, without applying any precedences (see "ParseOps")
opsPattern :: SrcLoc -> Ops Pattern -> Pattern
opsPattern _ (OpAtom a) = a
opsPattern loc (OpUn _ _) = fatal $ stageMsg StageParse loc "unary operator in pattern"
opsPattern loc (OpBin o l r) = PatCons o [opsPattern loc l, opsPattern loc r]

instance HasVar Exp where
  unVar (Var v) = Just v
  unVar Any = Just ignored
  unVar (ExpLoc _ e) = unVar e
  unVar (Ops e) = unVar e
  unVar _ = Nothing

instance HasVar Pattern where
  unVar (PatVar v) = Just v
  unVar PatAny = Just ignored
  unVar (PatLoc _ p) = unVar p
  unVar (PatOps p) = unVar p
  unVar _ = Nothing

-- Pretty printing

instance Pretty Decl where
  pretty' (SpecD f t) =
    f <+> "::" <+> t
  pretty' (DefD f args e) =
    nestedPunct '=' (prettyop f args) e
  pretty' (LetD p e) =
    nestedPunct '=' p e
  pretty' (ExpD e) =
    pretty' e
  pretty' (Data t args []) =
    "data" <+> prettyap t args
  pretty' (Data t args l) =
    nested ("data" <+> prettyap t args <+> "of") $
      vcat $ map (uncurry prettyop) l
  pretty' (Infix pf syms) =
    pf <+> punctuate ',' (map (pguard (-1)) syms)
  pretty' (Import v) =
    "import" <+> v

instance Pretty Prog where
  pretty' = vcat

instance Pretty DataField where
  pretty' (DataField Nothing t) = pretty' t
  pretty' (DataField (Just n) t) = 2 #> n <+> "::" <+> t

instance Pretty Exp where
  pretty' (Spec e t) = 2 #> pguard 2 e <+> "::" <+> t
  pretty' (Let s p e body) = 1 #>
    sStatic s "let" <+> p <+> '=' <+> pretty e <+> "in" $$ pretty body
  pretty' (Def f args e body) = 1 #>
    nestedPunct '=' ("let" <+> prettyop f args)
      (pretty e <+> "in" $$ pretty body)
  pretty' (Case s cases) = 1 #> pretty' (CaseGroup s cases)
  pretty' (If s c e1 e2) = 1 #>
    sStatic s "if" <+> pretty c <+> "then" <+> pretty e1 <+> "else" <+> pretty e2
  pretty' (Lambda pl e) = 1 #>
    hsep (map (<+> "->") pl) <+> pguard 1 e
  pretty' (Apply e el) = prettyop e el
  pretty' (Var v) = pretty' v
  pretty' (Int i) = pretty' i
  pretty' (Char c) = pretty' (show c)
  pretty' (String s) = pretty' (show s)
  pretty' Any = pretty' '_'
  pretty' (List el) = pretty' $ brackets $ 3 #> punctuate ',' el
  pretty' (Ops o) = pretty' o
  pretty' (Equals v e) = 0 #> v <+> '=' <+> pguard 0 e
  pretty' (Seq q) = nested "do" (pretty $ vcat q) -- XXX not valid syntax (yet)
  pretty' (ExpLoc _ e) = pretty' e

instance Pretty Case where
  pretty' (CaseMatch pcl) = nested "of" (vcat (map (uncurry (<+>)) pcl))
  pretty' (CaseGuard g) = pretty' g

instance Pretty CaseTail where
  pretty' (CaseGroup s c) = nested (sStatic s "case") (vcat $ map (uncurry (<+>)) c)
  pretty' (CaseBody e) = "->" <+> pretty e

instance Pretty Stmt where
  pretty' (StmtExp e) = pretty' e
  pretty' (StmtLet p e) = p <+> '=' <+> e
  pretty' (StmtDef f args e) = nestedPunct '=' (prettyop f args) e

patToExp :: Pattern -> Exp
patToExp (PatAs v p) = Equals v (patToExp p)
patToExp (PatSpec p t) = Spec (patToExp p) t
patToExp (PatCons c pl) = Apply (Var c) (map patToExp pl)
patToExp (PatOps o) = Ops (fmap patToExp o)
patToExp (PatVar v) = Var v
patToExp (PatInt i) = Int i
patToExp (PatChar c) = Char c
patToExp (PatString s) = String s
patToExp (PatList pl) = List (map patToExp pl)
patToExp (PatLambda pl p) = Lambda pl (patToExp p)
patToExp (PatTrans t p) = Apply (Var t) [patToExp p]
patToExp PatAny = Any
patToExp (PatLoc l p) = ExpLoc l (patToExp p)

instance Pretty Pattern where
  pretty' = pretty' . patToExp

expTypeDesc :: Exp -> String
expTypeDesc (Def {}) = "let"
expTypeDesc (Let {}) = "let"
expTypeDesc (Lambda {}) = "lambda"
expTypeDesc (Apply {}) = "apply"
expTypeDesc (Var {}) = "variable"
expTypeDesc (Int {}) = "integer"
expTypeDesc (Char {}) = "character"
expTypeDesc (String {}) = "string"
expTypeDesc (Any {}) = show (quoted '_')
expTypeDesc (List {}) = "list"
expTypeDesc (Ops {}) = "operator"
expTypeDesc (Equals {}) = "equals"
expTypeDesc (Spec {}) = "type specifier"
expTypeDesc (Case {}) = "case"
expTypeDesc (If {}) = "if"
expTypeDesc (Seq {}) = "sequence"
expTypeDesc (ExpLoc _ e) = expTypeDesc e

patTypeDesc :: Pattern -> String
patTypeDesc = expTypeDesc . patToExp
