{-# LANGUAGE DeriveFoldable, DeriveFunctor, FlexibleInstances,
             OverloadedStrings, StandaloneDeriving #-}

-- | This module implements a layer around the prettyprinter package, making it
-- easier to use.
module Nixfmt.Predoc
    ( text
    , sepBy
    , hcat
    , group
    , nest
    , softline'
    , line'
    , softline
    , line
    , hardspace
    , hardline
    , emptyline
    , newline
    , Doc
    , Pretty
    , pretty
    , flatten
    , fixup
    , layout
    ) where

import Data.List hiding (group)
import Data.Text as Text (Text, concat, length, pack, replicate)

data Tree a
    = EmptyTree
    | Leaf a
    | Node (Tree a) (Tree a)
    deriving (Show, Eq, Functor, Foldable)

-- | Sequential Spacings are reduced to a single Spacing by taking the maximum.
-- This means that e.g. a Space followed by an Emptyline results in just an
-- Emptyline.
data Spacing
    = Softbreak
    | Break
    | Hardspace
    | Softspace
    | Space
    | Hardline
    | Emptyline
    | Newlines Int
    deriving (Show, Eq, Ord)

data Predoc f
    = Text Text
    | Spacing Spacing
    -- | Group predoc indicates either all or none of the Spaces and Breaks in
    -- predoc should be converted to line breaks.
    | Group (f (Predoc f))
    -- | Nest n predoc indicates all line start in predoc should be indented by
    -- n more spaces than the surroundings.
    | Nest Int (f (Predoc f))

deriving instance Eq (Predoc Tree)
deriving instance Eq (Predoc [])
deriving instance Show (Predoc Tree)
deriving instance Show (Predoc [])

type Doc = Tree (Predoc Tree)
type DocList = [Predoc []]

class Pretty a where
    pretty :: a -> Doc

instance Pretty Text where
    pretty = Leaf . Text

instance Pretty String where
    pretty = Leaf . Text . pack

instance Pretty Doc where
    pretty = id

instance Pretty a => Pretty (Maybe a) where
    pretty Nothing  = mempty
    pretty (Just x) = pretty x

instance Semigroup (Tree a) where
    left <> right = Node left right

instance Monoid (Tree a) where
    mempty = EmptyTree

text :: Text -> Doc
text = Leaf . Text

group :: Pretty a => a -> Doc
group = Leaf . Group . pretty

nest :: Int -> Doc -> Doc
nest level = Leaf . Nest level

softline' :: Doc
softline' = Leaf (Spacing Softbreak)

line' :: Doc
line' = Leaf (Spacing Break)

softline :: Doc
softline = Leaf (Spacing Softspace)

line :: Doc
line = Leaf (Spacing Space)

hardspace :: Doc
hardspace = Leaf (Spacing Hardspace)

hardline :: Doc
hardline = Leaf (Spacing Hardline)

emptyline :: Doc
emptyline = Leaf (Spacing Emptyline)

newline :: Doc
newline = Leaf (Spacing (Newlines 1))

sepBy :: Pretty a => Doc -> [a] -> Doc
sepBy separator = mconcat . intersperse separator . map pretty

-- | Concatenate documents horizontally without spacing.
hcat :: Pretty a => [a] -> Doc
hcat = mconcat . map pretty

flatten :: Doc -> DocList
flatten = go []
    where go xs (Node x y)           = go (go xs y) x
          go xs EmptyTree            = xs
          go xs (Leaf (Group tree))  = Group (go [] tree) : xs
          go xs (Leaf (Nest l tree)) = Nest l (go [] tree) : xs
          go xs (Leaf (Spacing l))   = Spacing l : xs
          go xs (Leaf (Text ""))     = xs
          go xs (Leaf (Text t))      = Text t : xs

isSpacing :: Predoc f -> Bool
isSpacing (Spacing _) = True
isSpacing _           = False

spanEnd :: (a -> Bool) -> [a] -> ([a], [a])
spanEnd p = fmap reverse . span p . reverse

-- | Fix up a DocList in multiple stages:
-- - First, all spacings are moved out of Groups and Nests and empty Groups and
--   Nests are removed.
-- - Now, all consecutive Spacings are ensured to be in the same list, so each
--   sequence of Spacings can be merged into a single one.
-- - Finally, Spacings right before a Nest should be moved inside in order to
--   get the right indentation.
fixup :: DocList -> DocList
fixup = moveLinesIn . mergeLines . concatMap moveLinesOut

moveLinesOut :: (Predoc []) -> DocList
moveLinesOut (Group xs) =
    let movedOut     = concatMap moveLinesOut xs
        (pre, rest)  = span isSpacing movedOut
        (post, body) = spanEnd isSpacing rest
    in case body of
            [] -> pre ++ post
            _  -> pre ++ (Group body : post)

moveLinesOut (Nest level xs) =
    let movedOut     = concatMap moveLinesOut xs
        (pre, rest)  = span isSpacing movedOut
        (post, body) = spanEnd isSpacing rest
    in case body of
            [] -> pre ++ post
            _  -> pre ++ (Nest level body : post)

moveLinesOut x = [x]

mergeSpacings :: Spacing -> Spacing -> Spacing
mergeSpacings x y | x > y               = mergeSpacings y x
mergeSpacings Break        Softspace    = Space
mergeSpacings Break        Hardspace    = Space
mergeSpacings Softbreak    Hardspace    = Softspace
mergeSpacings (Newlines x) (Newlines y) = Newlines (x + y)
mergeSpacings Emptyline    (Newlines x) = Newlines (x + 2)
mergeSpacings Hardspace    (Newlines x) = Newlines x
mergeSpacings _            (Newlines x) = Newlines (x + 1)
mergeSpacings _            y            = y

mergeLines :: DocList -> DocList
mergeLines []                           = []
mergeLines (Spacing a : Spacing b : xs) = mergeLines $ Spacing (mergeSpacings a b) : xs
mergeLines (Text a : Text b : xs)       = mergeLines $ Text (a <> b) : xs
mergeLines (Text "" : xs)               = mergeLines xs
mergeLines (Group xs : ys)              = Group (mergeLines xs) : mergeLines ys
mergeLines (Nest n xs : ys)             = Nest n (mergeLines xs) : mergeLines ys
mergeLines (x : xs)                     = x : mergeLines xs

moveLinesIn :: DocList -> DocList
moveLinesIn [] = []
moveLinesIn (Spacing l : Nest level xs : ys) =
    Nest level (Spacing l : moveLinesIn xs) : moveLinesIn ys

moveLinesIn (Nest level xs : ys) =
    Nest level (moveLinesIn xs) : moveLinesIn ys

moveLinesIn (Group xs : ys) =
    Group (moveLinesIn xs) : moveLinesIn ys

moveLinesIn (x : xs) = x : moveLinesIn xs

layout :: Pretty a => Int -> a -> Text
layout w = layoutGreedy w . fixup . flatten . pretty

-- 1. Flatten Docs to DocLists.
-- 2. Move and merge Spacings.
-- 3. Convert Softlines to Grouped Lines and Hardspaces to Texts.
-- 4. For each Text or Group, try to fit as much as possible on a line
-- 5. For each Group, if it fits on a single line, render it that way.
-- 6. If not, convert lines to hardlines and unwrap the group

-- | To support i18n, this function needs to be patched.
textWidth :: Text -> Int
textWidth = Text.length

-- | Attempt to fit a list of documents in a single line of a specific width.
fits :: Int -> DocList -> Maybe Text
fits c _ | c < 0 = Nothing
fits _ [] = Just ""
fits c (x:xs) = case x of
    Text t               -> (t<>) <$> fits (c - textWidth t) xs
    Spacing Softbreak    -> fits c xs
    Spacing Break        -> fits c xs
    Spacing Softspace    -> (" "<>) <$> fits (c - 1) xs
    Spacing Space        -> (" "<>) <$> fits (c - 1) xs
    Spacing Hardspace    -> (" "<>) <$> fits (c - 1) xs
    Spacing Hardline     -> Nothing
    Spacing Emptyline    -> Nothing
    Spacing (Newlines _) -> Nothing
    Group ys             -> fits c $ ys ++ xs
    Nest _ ys            -> fits c $ ys ++ xs

-- | Find the width of the first line in a list of documents, using target
-- width 0, which always forces line breaks when possible.
firstLineWidth :: DocList -> Int
firstLineWidth []                       = 0
firstLineWidth (Text t : xs)            = textWidth t + firstLineWidth xs
firstLineWidth (Spacing Hardspace : xs) = 1 + firstLineWidth xs
firstLineWidth (Spacing _ : _)          = 0
firstLineWidth (Nest _ xs : ys)         = firstLineWidth (xs ++ ys)
firstLineWidth (Group xs : ys)          = firstLineWidth (xs ++ ys)

-- | Check if the first line in a list of documents fits a target width given
-- a maximum width, without breaking up groups.
firstLineFits :: Int -> Int -> DocList -> Bool
firstLineFits targetWidth maxWidth docs = go maxWidth docs
    where go c _ | c < 0                = False
          go c []                       = maxWidth - c <= targetWidth
          go c (Text t : xs)            = go (c - textWidth t) xs
          go c (Spacing Hardspace : xs) = go (c - 1) xs
          go c (Spacing _ : _)          = maxWidth - c <= targetWidth
          go c (Nest _ ys : xs)         = go c (ys ++ xs)
          go c (Group ys : xs)          =
              case fits (c - firstLineWidth xs) ys of
                   Nothing -> go c (ys ++ xs)
                   Just t  -> go (c - textWidth t) xs

data Chunk = Chunk Int (Predoc [])

indent :: Int -> Int -> Text
indent n i = Text.replicate n "\n" <> Text.replicate i " "

unChunk :: Chunk -> Predoc []
unChunk (Chunk _ doc) = doc

layoutGreedy :: Int -> DocList -> Text
layoutGreedy w doc = Text.concat $ go 0 [Chunk 0 $ Group doc]
    where go _ [] = []
          go c (Chunk i x : xs) = case x of
            Text t               -> t   : go (c + textWidth t) xs

            Spacing Break        -> indent 1 i : go i xs
            Spacing Space        -> indent 1 i : go i xs
            Spacing Hardspace    -> " "        : go (c + 1) xs
            Spacing Hardline     -> indent 1 i : go i xs
            Spacing Emptyline    -> indent 2 i : go i xs
            Spacing (Newlines n) -> indent n i : go i xs

            Spacing Softbreak
              | firstLineFits (w - c) (w - i) (map unChunk xs)
                                 -> go c xs
              | otherwise        -> indent 1 i : go i xs

            Spacing Softspace
              | firstLineFits (w - c - 1) (w - i) (map unChunk xs)
                                 -> " " : go (c + 1) xs
              | otherwise        -> indent 1 i : go i xs

            Nest l ys            -> go c $ map (Chunk (i + l)) ys ++ xs
            Group ys             ->
                case fits (w - c - firstLineWidth (map unChunk xs)) ys of
                     Nothing     -> go c $ map (Chunk i) ys ++ xs
                     Just t      -> t : go (c + textWidth t) xs
