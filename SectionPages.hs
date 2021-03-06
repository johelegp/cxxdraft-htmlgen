{-# OPTIONS_GHC -fno-warn-tabs #-}
{-# LANGUAGE OverloadedStrings, RecordWildCards, TupleSections, ViewPatterns #-}

module SectionPages
	( writeSectionFiles
	, writeSingleSectionFile
	, writeFiguresFile
	, writeTablesFile
	, writeIndexFiles
	, writeFootnotesFile
	, writeCssFile
	, writeXrefDeltaFiles
	) where

import Prelude hiding ((++), (.), writeFile)
import System.Directory (createDirectoryIfMissing)
import System.IO (hFlush, stdout)
import Control.Monad (forM_, when)
import Control.Parallel (par)
import System.Process (readProcess)
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Text.Lazy as LazyText
import qualified Data.Text.Lazy.Builder as TextBuilder
import Render (render, concatRender, simpleRender2, outputDir, renderFig,
	defaultRenderContext, renderTab, RenderContext(..), SectionFileStyle(..), Page(..),
	linkToSection, squareAbbr, linkToRemoteTable, fileContent, applySectionFileStyle,
	secnum, Link(..), renderLatexParas, isSectionPage, parentLink)
import Document
import Util (urlChars, (++), (.), h, anchor, xml, Anchor(..), Text, writeFile, readFile, intercalateBuilders)

renderParagraph :: RenderContext -> TextBuilder.Builder
renderParagraph ctx@RenderContext{nearestEnclosing=Left Paragraph{..}, draft=Draft{..}} =
		(case paraNumber of
			Just i -> renderNumbered (Text.pack $ show i)
			Nothing -> id)
		$ (if paraInItemdescr then xml "div" [("class", "itemdescr")] else id)
		$ (sourceLink
		  ++ renderLatexParas paraElems ctx'{extraIndentation=if paraInItemdescr then 3 else 0})
	where
		urlBase = Text.replace "/commit/" "/tree/" commitUrl ++ "/source/"
		sourceLink :: TextBuilder.Builder
		sourceLink
			| Just SourceLocation{..} <- paraSourceLoc =
				xml "div" [("class", "sourceLinkParent")]
				$ simpleRender2 $ anchor
					{ aClass = "sourceLink"
					, aText = "#"
					, aHref = urlBase ++ Text.pack (sourceFile ++ "#L" ++ show sourceLine) }
			| otherwise = ""

		renderNumbered :: Text -> TextBuilder.Builder -> TextBuilder.Builder
		renderNumbered n =
			let
				idTag = if isSectionPage (page ctx) then [("id", idPrefix ctx ++ n)] else []
				a = anchor
					{ aClass = "marginalized"
					, aHref  =
						if isSectionPage (page ctx)
							then "#" ++ urlChars (idPrefix ctx) ++ n
							else "SectionToSection/" ++ urlChars (abbreviation paraSection) ++ "#" ++ n
					, aText  = TextBuilder.fromText n }
			in
				xml "div" (("class", "para") : idTag) .
				(xml "div" [("class", "marginalizedparent")] (render a ctx') ++)
		ctx' = case paraNumber of
			Just n -> ctx{ idPrefix = idPrefix ctx ++ Text.pack (show n) ++ "." }
			Nothing -> ctx
renderParagraph _ = undefined

renderSection :: RenderContext -> Maybe Section -> Bool -> Section -> (TextBuilder.Builder, Bool)
renderSection context specific parasEmitted s@Section{..}
	| full = (, True) $
		idDiv $ header ++
		mconcat (map
			(\p -> renderParagraph (context{nearestEnclosing=Left p,idPrefix=if parasEmitted then secOnPage ++ "-" else ""}))
			paragraphs) ++
		concatRender sectionFootnotes context{nearestEnclosing=Right s} ++
		mconcat (fst . renderSection context Nothing True . subsections)
	| not anysubcontent = ("", False)
	| otherwise =
		( header ++
		  mconcat (fst . renderSection context specific False . subsections)
		, anysubcontent )
	where
		idDiv
			| specific == Just s = id
			| otherwise = xml "div" [("id", secOnPage), ("class", "section")]
		secOnPage :: Text
		secOnPage = case page context of
			SectionPage parent -> parentLink parent abbreviation
			_ -> abbreviation
		full = specific == Nothing || specific == Just s
		header = sectionHeader (min 4 $ 1 + length parents) s
			(if specific == Nothing && isSectionPage (page context) then "#" ++ urlChars secOnPage else "")
			abbr context
		abbr
			| specific == Just s && not (null parents)
				= anchor
			| Just sp <- specific, sp /= s, not (null parents)
				= anchor{aHref = "SectionToSection/" ++ urlChars abbreviation ++ "#" ++ parentLink s (Document.abbreviation sp)}
			| otherwise = linkToSection
					(if null parents then SectionToToc else SectionToSection)
					abbreviation
		anysubcontent =
			or $ map (snd . renderSection context specific True)
			   $ subsections

sectionFilePath :: FilePath -> SectionFileStyle -> String
sectionFilePath n Bare = outputDir ++ n
sectionFilePath n WithExtension = outputDir ++ n ++ ".html"
sectionFilePath n InSubdir = outputDir ++ n ++ "/index.html"

sectionFileContent :: SectionFileStyle -> TextBuilder.Builder -> TextBuilder.Builder -> Text
sectionFileContent sfs title body = applySectionFileStyle sfs $ LazyText.toStrict $ TextBuilder.toLazyText $
	fileContent (if sfs == InSubdir then "../" else "") title "" body

writeSectionFile :: FilePath -> SectionFileStyle -> TextBuilder.Builder -> TextBuilder.Builder -> IO ()
writeSectionFile n sfs title body = do
	when (sfs == InSubdir) $ createDirectoryIfMissing True (outputDir ++ n)
	writeFile (sectionFilePath n sfs) (sectionFileContent sfs title body)

sectionHeader :: Int -> Section -> Text -> Anchor -> RenderContext -> TextBuilder.Builder
sectionHeader hLevel s@Section{..} secnumHref abbr_ref ctx
    | isDef = xml "h4" [("style", "margin-bottom:3pt")] $ num ++ abbrR ++ name
    | otherwise = h hLevel $ num ++ " " ++ name ++ " " ++ abbrR
  where
    num = secnum secnumHref s
    abbrR = simpleRender2 abbr_ref{aClass = "abbr_ref", aText = squareAbbr abbreviation}
    name = render sectionName ctx{inSectionTitle=True}
    isDef = isDefinitionSection sectionKind

writeFiguresFile :: SectionFileStyle -> Draft -> IO ()
writeFiguresFile sfs draft = writeSectionFile "fig" sfs "14882: Figures" $
	"<h1>List of Figures <a href='SectionToToc/fig' class='abbr_ref'>[fig]</a></h1>"
	++ mconcat (uncurry r . figures draft)
	where
		r :: Paragraph -> Figure -> TextBuilder.Builder
		r p f@Figure{figureSection=s@Section{..}, ..} =
			"<hr>" ++
			sectionHeader 4 s "" anchor{
				aHref = "SectionToSection/" ++ urlChars abbreviation
					++ "#" ++ urlChars figureAbbr } defaultRenderContext
			++ renderFig True f defaultRenderContext{draft=draft, nearestEnclosing=Left p, page=FiguresPage}

writeTablesFile :: SectionFileStyle -> Draft -> IO ()
writeTablesFile sfs draft = writeSectionFile "tab" sfs "14882: Tables" $
	"<h1>List of Tables <a href='SectionToToc/tab' class='abbr_ref'>[tab]</a></h1>"
	++ mconcat (uncurry r . tables draft)
	where
		r :: Paragraph -> Table -> TextBuilder.Builder
		r p t@Table{tableSection=s@Section{..}, ..} =
			"<hr>" ++
			sectionHeader 4 s "" (linkToRemoteTable t) defaultRenderContext
			++ renderTab True t defaultRenderContext{draft=draft, nearestEnclosing=Left p, page=TablesPage}

writeFootnotesFile :: SectionFileStyle -> Draft -> IO ()
writeFootnotesFile sfs draft = writeSectionFile "footnotes" sfs "14882: Footnotes" $
	"<h1>List of Footnotes</h1>"
	++ mconcat (uncurry r . footnotes draft)
	where
		r :: Section -> Footnote -> TextBuilder.Builder
		r s fn = render fn defaultRenderContext{draft=draft, nearestEnclosing = Right s, page=FootnotesPage}

parAll :: [a] -> b -> b
parAll = flip $ foldl $ flip par

writeSingleSectionFile :: SectionFileStyle -> Draft -> String -> IO ()
writeSingleSectionFile sfs draft abbr = do
	let section@Section{..} = Document.sectionByAbbr draft (Text.pack abbr)
	let baseFilename = Text.unpack abbreviation
	writeSectionFile baseFilename sfs (squareAbbr abbreviation) $ mconcat $ fst . renderSection (defaultRenderContext{draft=draft,page=SectionPage section}) (Just section) False . chapters draft
	putStrLn $ "  " ++ baseFilename

writeSectionFiles :: SectionFileStyle -> Draft -> IO ()
writeSectionFiles sfs draft = do
	putStr "  sections..";
	let
	  secs = Document.sections draft
	  renSec section@Section{..} = (Text.unpack abbreviation, sectionFileContent sfs title body)
	    where
	      title = squareAbbr abbreviation
	      body = mconcat $ fst . renderSection (defaultRenderContext{draft=draft,page=SectionPage section}) (Just section) False . chapters draft
	  fullbody = mconcat $ fst . renderSection defaultRenderContext{draft=draft, page=FullPage} Nothing True . chapters draft
	  fullfile = ("full", sectionFileContent sfs "14882" fullbody)
	  files = fullfile : map renSec secs
	  names = fst . files
	  contents = snd . files
	parAll contents $ forM_ (zip names contents) $ \(n, content) -> do
		putStr "."; hFlush stdout
		when (sfs == InSubdir) $ createDirectoryIfMissing True (outputDir ++ n)
		writeFile (sectionFilePath n sfs) content
	putStrLn $ " " ++ show (length secs)

writeIndexFiles :: SectionFileStyle -> Index -> IO ()
writeIndexFiles sfs index = forM_ (Map.toList index) $ \(Text.unpack -> cat, i) -> do
	putStrLn $ "  " ++ cat
	writeSectionFile cat sfs ("14882: " ++ indexCatName cat) $ h 1 (indexCatName cat) ++ render i defaultRenderContext{page=IndexPage}

writeCssFile :: IO ()
writeCssFile = do
	base <- Text.pack . readFile "14882.css"
	let
		replaceFonts =
			Text.replace
				".MJXc-TeX-sans-R {font-family: MJXc-TeX-sans-R,MJXc-TeX-sans-Rw}"
				".MJXc-TeX-sans-R {font-family: sans-serif}" .
			Text.replace
				".MJXc-TeX-type-R {font-family: MJXc-TeX-type-R,MJXc-TeX-type-Rw}"
				".MJXc-TeX-type-R {font-family: monospace}" .
			Text.replace
				".MJXc-TeX-main-R {font-family: MJXc-TeX-main-R,MJXc-TeX-main-Rw}"
				".MJXc-TeX-main-R {}" .
			Text.replace
				".MJXc-TeX-math-I {font-family: MJXc-TeX-math-I,MJXc-TeX-math-Ix,MJXc-TeX-math-Iw}"
				".MJXc-TeX-math-I {font-style: italic}" .
			Text.replace
				".MJXc-TeX-main-I {font-family: MJXc-TeX-main-I,MJXc-TeX-main-Ix,MJXc-TeX-main-Iw}"
				".MJXc-TeX-main-I {font-style: italic}"
		-- Replace fonts to make sure code in formulas matches code in code blocks, etc.
	mjx <- Text.replace "display: block" "display: block;background:inherit" . replaceFonts . Text.pack .
		readProcess "tex2html" ["--css", ""] ""
	writeFile (outputDir ++ "/14882.css") (base ++ mjx)

writeXrefDeltaFiles :: SectionFileStyle -> Draft -> IO ()
writeXrefDeltaFiles sfs draft = forM_ (xrefDelta draft) $ \(from, to) ->
	writeSectionFile (Text.unpack from) sfs (squareAbbr from) $
		if to == []
			then "Subclause " ++ squareAbbr from ++ " was removed."
			else "See " ++ intercalateBuilders ", " (flip render ctx . to) ++ "."
	where ctx = defaultRenderContext{draft=draft, page=XrefDeltaPage}
