-- | Source file location annotations for reporting

module SrcLoc
  ( SrcLoc, srcFile, srcLine, srcCol
  , beforeLoc
  , rangeLoc
  , startLoc
  , incrLoc
  , sameLine
  , noLoc
  , hasLoc
  , Loc(..)
  , srcLoc, unLoc
  , HasLoc(..)
  ) where

import Data.Maybe
import Data.Monoid

import Pretty

-- Pull in definition of SrcLoc
import Gen.SrcLoc

-- !See definition of Loc in srcLoc.duck
srcLoc :: Loc a -> SrcLoc
srcLoc (L l _) = l
unLoc (L _ x) = x

instance Functor Loc where
  fmap f (L l x) = L l (f x)

showOff :: Int -> String -> String
showOff 0 = ('$':)
showOff n
  | n < 0 = ('$':) . shows (negate n)
  | otherwise = shows n

instance Show SrcLoc where
  showsPrec _ (SrcNone "") = showString "<unknown>"
  showsPrec _ (SrcNone s) = showString s
  showsPrec _ (SrcLoc file line col) = (file++) . (':':) . showOff line . (':':) . showOff col
  showsPrec _ (SrcRng file line col line' col')
    | line == line' = (file++) . (':':) . showOff line . (':':) . showOff col . ('-':) . showOff col'
    | otherwise = (file++) . (':':) . showOff line . (':':) . showOff col . ('-':) . showOff line' . (':':) . showOff col'

-- By default, locations drop away when printing
instance Show t => Show (Loc t) where
  show (L _ x) = show x

instance Pretty t => Pretty (Loc t) where
  pretty' (L _ x) = pretty' x

class HasLoc a where
  loc :: a -> SrcLoc
  maybeLoc :: a -> Maybe SrcLoc

  loc = fromMaybe noLoc . maybeLoc
  maybeLoc a = if hasLoc l then Just l else Nothing where l = loc a

instance HasLoc SrcLoc where loc = id
instance HasLoc (Loc a) where loc = srcLoc

instance HasLoc a => HasLoc [a] where
  loc = mconcat . map loc

instance Pretty SrcLoc where
  pretty l
    | hasLoc l = pretty (show l)
    | otherwise = pretty ()

-- |The location immediately before another
beforeLoc :: SrcLoc -> SrcLoc
beforeLoc l@(SrcNone _) = l
beforeLoc (SrcLoc f l 1) = SrcLoc f (pred l) 0
beforeLoc (SrcLoc f l c) = SrcLoc f l (pred c)
beforeLoc (SrcRng f l c _ _) = beforeLoc (SrcLoc f l c)

startLoc :: String -> SrcLoc
startLoc file = SrcLoc file 1 1

incrLoc :: SrcLoc -> Char -> SrcLoc
incrLoc (SrcLoc f l _) '\n' = SrcLoc f (l+1) 1
incrLoc (SrcLoc f l c) '\t' = SrcLoc f l (1 + 8 * div (c+7) 8)
incrLoc (SrcLoc f l c) _    = SrcLoc f l (c+1)
incrLoc _ _ = error "incrLoc works only on SrcLoc, not SrcNone or SrcRng"

sameLine :: SrcLoc -> SrcLoc -> Bool
sameLine s t = srcLine s == srcLine t

joinFile :: String -> String -> String
joinFile "" s = s
joinFile s _ = s {- this is probably too slow to be worth it:
joinFile s "" = s
joinFile s1 s2 = s1
  | s1 == s2 = s1
  | otherwise = s1 ++ ';' : s2 -}

joinLocs :: SrcLoc -> String -> Int -> Int -> SrcLoc
joinLocs (SrcNone s1) s2 r2 c2 = SrcLoc (joinFile s1 s2) r2 c2
joinLocs l s2 r2 c2 
  | srcLine l == r2 && srcCol l == c2 = SrcLoc s r2 c2
  | otherwise = SrcRng s (srcLine l) (srcCol l) r2 c2
  where s = joinFile (srcFile l) s2

setFile :: SrcLoc -> String -> SrcLoc
setFile (SrcNone _) f = SrcNone f
setFile (SrcLoc _ r c) f = SrcLoc f r c
setFile (SrcRng _ r c r2 c2) f = SrcRng f r c r2 c2

instance Monoid SrcLoc where
  mempty = SrcNone ""

  mappend (SrcNone s) l = setFile l (joinFile s (srcFile l))
  mappend l (SrcNone s) = setFile l (joinFile (srcFile l) s)
  mappend l (SrcLoc s2 r2 c2) = joinLocs l s2 r2 c2
  mappend l (SrcRng s2 _ _ r2 c2) = joinLocs l s2 r2 c2

rangeLoc :: SrcLoc -> SrcLoc -> SrcLoc
rangeLoc l = mappend l . beforeLoc

noLoc :: SrcLoc
noLoc = mempty

hasLoc :: SrcLoc -> Bool
hasLoc (SrcNone "") = False
hasLoc _ = True

{-
srcRng :: SrcLoc -> SrcLoc -> SrcLoc
srcRng = mappend

srcLocStart :: SrcLoc -> SrcLoc
srcLocStart (SrcRng s r c _ _) = SrcLoc s r c
srcLocStart l = l

srcLocEnd :: SrcLoc -> SrcLoc
srcLocEnd (SrcRng s _ _ r c) = SrcLoc s r c
srcLocEnd l = l
-}
