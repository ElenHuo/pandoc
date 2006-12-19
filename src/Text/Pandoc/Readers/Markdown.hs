-- | Convert markdown to Pandoc document.
module Text.Pandoc.Readers.Markdown ( 
                                     readMarkdown 
                                    ) where

import Data.List ( findIndex, sortBy )
import Text.ParserCombinators.Pandoc
import Text.Pandoc.Definition
import Text.Pandoc.Readers.LaTeX ( rawLaTeXInline, rawLaTeXEnvironment )
import Text.Pandoc.Shared 
import Text.Pandoc.Readers.HTML ( rawHtmlInline, rawHtmlBlock, anyHtmlBlockTag, 
                                               anyHtmlInlineTag )
import Text.Pandoc.HtmlEntities ( decodeEntities )
import Text.Regex ( matchRegex, mkRegex )
import Text.ParserCombinators.Parsec

-- | Read markdown from an input string and return a Pandoc document.
readMarkdown :: ParserState -> String -> Pandoc
readMarkdown = readWith parseMarkdown

-- | Parse markdown string with default options and print result (for testing).
testString :: String -> IO ()
testString = testStringWith parseMarkdown 

--
-- Constants and data structure definitions
--

spaceChars = " \t"
endLineChars = "\n"
labelStart = '['
labelEnd = ']'
labelSep = ':'
srcStart = '('
srcEnd = ')'
imageStart = '!'
noteStart = '^'
codeStart = '`'
codeEnd = '`'
emphStart = '*'
emphEnd = '*'
emphStartAlt = '_'
emphEndAlt = '_'
autoLinkStart = '<'
autoLinkEnd = '>'
mathStart = '$'
mathEnd = '$'
bulletListMarkers = "*+-"
orderedListDelimiters = ".)"
escapeChar = '\\'
hruleChars = "*-_"
quoteChars = "'\""
atxHChar = '#'
titleOpeners = "\"'("
setextHChars = ['=','-']
blockQuoteChar = '>'
hyphenChar = '-'

-- treat these as potentially non-text when parsing inline:
specialChars = [escapeChar, labelStart, labelEnd, emphStart, emphEnd, emphStartAlt, 
                emphEndAlt, codeStart, codeEnd, autoLinkEnd, autoLinkStart, mathStart, 
                mathEnd, imageStart, noteStart, hyphenChar]

--
-- auxiliary functions
--

-- | Skip a single endline if there is one.
skipEndline = option Space endline

indentSpaces = do
  state <- getState
  let tabStop = stateTabStop state
  oneOfStrings [ "\t", (replicate tabStop ' ') ] <?> "indentation"

skipNonindentSpaces = do
  state <- getState
  let tabStop = stateTabStop state
  choice (map (\n -> (try (count n (char ' ')))) (reverse [0..(tabStop - 1)]))

--
-- document structure
--

titleLine = try (do
  char '%'
  skipSpaces
  line <- manyTill inline newline
  return line)

authorsLine = try (do
  char '%'
  skipSpaces
  authors <- sepEndBy (many1 (noneOf ",;\n")) (oneOf ",;")
  newline
  return (map removeLeadingTrailingSpace authors))

dateLine = try (do
  char '%'
  skipSpaces
  date <- many (noneOf "\n")
  newline
  return (removeTrailingSpace date))

titleBlock = try (do
  title <- option [] titleLine
  author <- option [] authorsLine
  date <- option "" dateLine
  option "" blanklines
  return (title, author, date))

-- | Returns the number assigned to a Note block
numberOfNote :: Block -> Int
numberOfNote (Note ref _) = (read ref) 
numberOfNote _ = 0 

parseMarkdown = do
  updateState (\state -> state { stateParseRaw = True }) -- need to parse raw HTML
  (title, author, date) <- option ([],[],"") titleBlock
  blocks <- parseBlocks
  let blocks' = filter (/= Null) blocks
  state <- getState
  let keys = reverse $ stateKeyBlocks state
  let notes = reverse $ stateNoteBlocks state
  let sortedNotes = sortBy (\x y -> compare (numberOfNote x) (numberOfNote y)) notes
  return (Pandoc (Meta title author date) (blocks' ++ sortedNotes ++ keys))

--
-- parsing blocks
--

parseBlocks = do
  result <- manyTill block eof
  return result

block = choice [ codeBlock, note, referenceKey, header, hrule, list, blockQuote, rawHtmlBlocks, 
                 rawLaTeXEnvironment, para, plain, blankBlock, nullBlock ] <?> "block"

--
-- header blocks
--

header = choice [ setextHeader, atxHeader ] <?> "header"

atxHeader = try (do
  lead <- many1 (char atxHChar)
  skipSpaces
  txt <- manyTill inline atxClosing
  return (Header (length lead) (normalizeSpaces txt)))

atxClosing = try (do
  skipMany (char atxHChar)
  skipSpaces
  newline
  option "" blanklines)

setextHeader = choice (map (\x -> setextH x) (enumFromTo 1 (length setextHChars)))

setextH n = try (do
    txt <- many1 (do {notFollowedBy newline; inline})
    endline
    many1 (char (setextHChars !! (n-1)))
    skipSpaces
    newline
    option "" blanklines
    return (Header n (normalizeSpaces txt)))

--
-- hrule block
--

hruleWith chr = 
    try (do
           skipSpaces
           char chr
           skipSpaces
           char chr
           skipSpaces
           char chr
           skipMany (oneOf (chr:spaceChars))
           newline
           option "" blanklines
           return HorizontalRule)

hrule = choice (map hruleWith hruleChars) <?> "hrule"

--
-- code blocks
--

indentedLine = try (do
    indentSpaces
    result <- manyTill anyChar newline
    return (result ++ "\n"))

-- two or more indented lines, possibly separated by blank lines
indentedBlock = try (do 
  res1 <- indentedLine
  blanks <- many blankline 
  res2 <- choice [indentedBlock, indentedLine]
  return (res1 ++ blanks ++ res2))

codeBlock = do
    result <- choice [indentedBlock, indentedLine]
    option "" blanklines
    return (CodeBlock (stripTrailingNewlines result))

--
-- note block
--

rawLine = try (do
    notFollowedBy' blankline
    notFollowedBy' noteMarker
    contents <- many1 nonEndline
    end <- option "" (do
                        newline
                        option "" indentSpaces
                        return "\n")
    return (contents ++ end))

rawLines = do
    lines <- many1 rawLine
    return (concat lines)

note = try (do
    ref <- noteMarker
    char ':'
    skipSpaces
    skipEndline
    raw <- sepBy rawLines (try (do {blankline; indentSpaces}))
    option "" blanklines
    -- parse the extracted text, which may contain various block elements:
    state <- getState
    let parsed = case runParser parseBlocks (state {stateParserContext = BlockQuoteState}) "block" ((joinWithSep "\n" raw) ++ "\n\n") of
                   Left err -> error $ "Raw block:\n" ++ show raw ++ "\nError:\n" ++ show err
                   Right result -> result 
    let identifiers = stateNoteIdentifiers state
    case (findIndex (== ref) identifiers) of
      Just n  -> updateState (\s -> s {stateNoteBlocks = 
                 (Note (show (n+1)) parsed):(stateNoteBlocks s)})
      Nothing -> updateState id 
    return Null)

--
-- block quotes
--

emacsBoxQuote = try (do
    string ",----"
    manyTill anyChar newline
    raw <- manyTill (try (do{ char '|'; 
                              option ' ' (char ' '); 
                              result <- manyTill anyChar newline; 
                              return result})) 
                     (string "`----")
    manyTill anyChar newline
    option "" blanklines
    return raw)

emailBlockQuoteStart = try (do
  skipNonindentSpaces
  char blockQuoteChar
  option ' ' (char ' ')
  return "> ")

emailBlockQuote = try (do
    emailBlockQuoteStart
    raw <- sepBy (many (choice [nonEndline, 
                                (try (do{ endline; 
                                          notFollowedBy' emailBlockQuoteStart;
                                          return '\n'}))])) 
           (try (do {newline; emailBlockQuoteStart}))
    newline <|> (do{ eof; return '\n'})
    option "" blanklines
    return raw)

blockQuote = do 
    raw <- choice [ emailBlockQuote, emacsBoxQuote ]
    -- parse the extracted block, which may contain various block elements:
    state <- getState
    let parsed = case runParser parseBlocks (state {stateParserContext = BlockQuoteState}) "block" ((joinWithSep "\n" raw) ++ "\n\n") of
                   Left err -> error $ "Raw block:\n" ++ show raw ++ "\nError:\n" ++ show err
                   Right result -> result
    return (BlockQuote parsed)

--
-- list blocks
--

list = choice [ bulletList, orderedList ] <?> "list"

bulletListStart = 
    try (do
           option ' ' newline -- if preceded by a Plain block in a list context
           skipNonindentSpaces
           notFollowedBy' hrule  -- because hrules start out just like lists
           oneOf bulletListMarkers
           spaceChar
           skipSpaces)

orderedListStart = 
    try (do
           option ' ' newline -- if preceded by a Plain block in a list context
           skipNonindentSpaces
           many1 digit <|> count 1 letter
           oneOf orderedListDelimiters
           oneOf spaceChars
           skipSpaces)

-- parse a line of a list item (start = parser for beginning of list item)
listLine start = try (do
  notFollowedBy' start
  notFollowedBy blankline
  notFollowedBy' (do{ indentSpaces; 
                      many (spaceChar);
                      choice [bulletListStart, orderedListStart]})
  line <- manyTill anyChar newline
  return (line ++ "\n"))

-- parse raw text for one list item, excluding start marker and continuations
rawListItem start = 
    try (do
           start
           result <- many1 (listLine start)
           blanks <- many blankline
           return ((concat result) ++ blanks))

-- continuation of a list item - indented and separated by blankline 
-- or (in compact lists) endline.
-- note: nested lists are parsed as continuations
listContinuation start = 
    try (do
           followedBy' indentSpaces
           result <- many1 (listContinuationLine start)
           blanks <- many blankline
           return ((concat result) ++ blanks))

listContinuationLine start = try (do
    notFollowedBy' blankline
    notFollowedBy' start
    option "" indentSpaces
    result <- manyTill anyChar newline
    return (result ++ "\n"))

listItem start = 
    try (do 
           first <- rawListItem start
           rest <- many (listContinuation start)
           -- parsing with ListItemState forces markers at beginning of lines to
           -- count as list item markers, even if not separated by blank space.
           -- see definition of "endline"
           state <- getState
           let parsed = case runParser parseBlocks (state {stateParserContext = ListItemState}) 
                        "block" raw of
                          Left err -> error $ "Raw block:\n" ++ raw ++ "\nError:\n" ++ show err
                          Right result -> result
                   where raw = concat (first:rest) 
           return parsed)

orderedList = 
    try (do
           items <- many1 (listItem orderedListStart)
           let items' = compactify items
           return (OrderedList items'))

bulletList = 
    try (do
           items <- many1 (listItem bulletListStart)
           let items' = compactify items
           return (BulletList items'))

--
-- paragraph block
--

para = try (do 
  result <- many1 inline
  newline
  choice [ (do{ followedBy' (oneOfStrings [">", ",----"]); return "" }), blanklines ]  
  let result' = normalizeSpaces result
  return (Para result'))

plain = do
  result <- many1 inline
  let result' = normalizeSpaces result
  return (Plain result')

-- 
-- raw html
--

rawHtmlBlocks = try (do
   htmlBlocks <- many1 rawHtmlBlock    
   let combined = concatMap (\(RawHtml str) -> str) htmlBlocks
   let combined' = if (last combined == '\n') then 
                       init combined  -- strip extra newline 
                   else 
                       combined 
   return (RawHtml combined'))

-- 
-- reference key
--

referenceKey = 
    try (do
           skipSpaces
           label <- reference
           char labelSep
           skipSpaces
           option ' ' (char autoLinkStart)
           src <- many (noneOf (titleOpeners ++ [autoLinkEnd] ++ endLineChars))
           option ' ' (char autoLinkEnd)
           tit <- option "" title 
           blanklines 
           return (Key label (Src (removeTrailingSpace src) tit))) 

-- 
-- inline
--

text = choice [ math, strong, emph, code2, code1, str, linebreak, tabchar, 
                whitespace, endline ] <?> "text"

inline = choice [ rawLaTeXInline, escapedChar, special, hyphens, text, ltSign, symbol ] <?> "inline"

special = choice [ noteRef, inlineNote, link, referenceLink, rawHtmlInline, autoLink, 
                   image ] <?> "link, inline html, note, or image"

escapedChar = escaped anyChar

ltSign = try (do
  notFollowedBy' rawHtmlBlocks -- don't return < if it starts html
  char '<'
  return (Str ['<']))

specialCharsMinusLt = filter (/= '<') specialChars

symbol = do 
  result <- oneOf specialCharsMinusLt
  return (Str [result])

hyphens = try (do
  result <- many1 (char '-')
  if (length result) == 1 then
      skipEndline   -- don't want to treat endline after hyphen as a space
    else
      do{ string ""; return Space }
  return (Str result))

-- parses inline code, between codeStart and codeEnd
code1 = 
    try (do 
           char codeStart
           result <- many (noneOf [codeEnd])
           char codeEnd
           let result' = removeLeadingTrailingSpace $ joinWithSep " " $ lines result -- get rid of any internal newlines
           return (Code result'))

-- parses inline code, between 2 codeStarts and 2 codeEnds
code2 = 
    try (do
           string [codeStart, codeStart]
           result <- manyTill anyChar (try (string [codeEnd, codeEnd]))
           let result' = removeLeadingTrailingSpace $ joinWithSep " " $ lines result -- get rid of any internal newlines
           return (Code result'))

mathWord = many1 (choice [(noneOf (" \t\n\\" ++ [mathEnd])), (try (do {c <- char '\\'; notFollowedBy (char mathEnd); return c}))])

math = try (do
  char mathStart
  notFollowedBy space
  words <- sepBy1 mathWord (many1 space)
  char mathEnd
  return (TeX ("$" ++ (joinWithSep " " words) ++ "$")))

emph = do
  result <- choice [ (enclosed (char emphStart) (char emphEnd) inline), 
                      (enclosed (char emphStartAlt) (char emphEndAlt) inline) ]
  return (Emph (normalizeSpaces result))

strong = do
  result <- choice [ (enclosed (count 2 (char emphStart)) (count 2 (char emphEnd)) inline), 
                     (enclosed (count 2 (char emphStartAlt)) (count 2 (char emphEndAlt)) inline)]
  return (Strong (normalizeSpaces result))

whitespace = do
  many1 (oneOf spaceChars) <?> "whitespace"
  return Space

tabchar = do
  tab
  return (Str "\t")

-- hard line break
linebreak = try (do
  oneOf spaceChars
  many1 (oneOf spaceChars) 
  endline
  return LineBreak )

nonEndline = noneOf endLineChars

str = do 
  result <- many1 ((noneOf (specialChars ++ spaceChars ++ endLineChars))) 
  return (Str (decodeEntities result))

-- an endline character that can be treated as a space, not a structural break
endline =
    try (do
           newline
           -- next line would allow block quotes without preceding blank line
           -- Markdown.pl does allow this, but there's a chance of a wrapped
           -- greater-than sign triggering a block quote by accident...
--         notFollowedBy' (choice [emailBlockQuoteStart, string ",----"])  
           notFollowedBy blankline
           -- parse potential list starts at beginning of line differently if in a list:
           st <- getState
           if (stateParserContext st) == ListItemState then 
               do
                 notFollowedBy' orderedListStart
                 notFollowedBy' bulletListStart
             else
               option () pzero
           return Space)

--
-- links
--

-- a reference label for a link
reference = do
  char labelStart
  notFollowedBy (char noteStart)
  label <- manyTill inline (char labelEnd)
  return (normalizeSpaces label)

-- source for a link, with optional title
source = 
    try (do 
           char srcStart
           option ' ' (char autoLinkStart)
           src <- many (noneOf ([srcEnd, autoLinkEnd] ++ titleOpeners))
           option ' ' (char autoLinkEnd)
           tit <- option "" title
           skipSpaces
           char srcEnd
           return (Src (removeTrailingSpace src) tit))

titleWith startChar endChar =
    try (do
           skipSpaces
           skipEndline  -- a title can be on the next line from the source
           skipSpaces
           char startChar
           tit <- manyTill (choice [ try (do {char '\\'; char endChar}), 
                                     (noneOf (endChar:endLineChars)) ]) (char endChar) 
           let tit' = gsub "\"" "&quot;" tit
           return tit')

title = choice [titleWith '(' ')', titleWith '"' '"', titleWith '\'' '\''] <?> "title"

link = choice [explicitLink, referenceLink] <?> "link"

explicitLink =
    try (do
           label <- reference
           src <- source 
           return (Link label src)) 

referenceLink = choice [referenceLinkDouble, referenceLinkSingle]

referenceLinkDouble =     -- a link like [this][/url/]
    try (do
           label <- reference
           skipSpaces
           skipEndline
           skipSpaces
           ref <- reference 
           return (Link label (Ref ref))) 

referenceLinkSingle =     -- a link like [this]
    try (do
           label <- reference
           return (Link label (Ref []))) 

autoLink =                -- a link <like.this.com>
    try (do
           notFollowedBy' anyHtmlBlockTag
           src <- between (char autoLinkStart) (char autoLinkEnd) 
                  (many (noneOf (spaceChars ++ endLineChars ++ [autoLinkEnd])))
           case (matchRegex emailAddress src) of
             Just _  -> return (Link [Str src] (Src ("mailto:" ++ src) ""))
             Nothing -> return (Link [Str src] (Src src ""))) 

emailAddress = mkRegex "([^@:/]+)@(([^.]+[.]?)*([^.]+))"  -- presupposes no whitespace

image = 
    try (do
           char imageStart
           (Link label src) <- link
           return (Image label src)) 

noteMarker = try (do
    char labelStart
    char noteStart
    manyTill (noneOf " \t\n") (char labelEnd))

noteRef = try (do
    ref <- noteMarker
    state <- getState
    let identifiers = (stateNoteIdentifiers state) ++ [ref] 
    updateState (\st -> st {stateNoteIdentifiers = identifiers})
    return (NoteRef (show (length identifiers))))

inlineNote = try (do
    char noteStart
    char labelStart
    contents <- manyTill inline (char labelEnd)
    state <- getState
    let identifiers = stateNoteIdentifiers state
    let ref = show $ (length identifiers) + 1
    let noteBlocks = stateNoteBlocks state
    updateState (\st -> st {stateNoteIdentifiers = (identifiers ++ [ref]),
                            stateNoteBlocks = (Note ref [Para contents]):noteBlocks})
    return (NoteRef ref))

