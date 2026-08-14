# Builds docs/pdf/vouch-design.pdf and docs/html/vouch-design.html from the Typst source.
$ErrorActionPreference = 'Stop'
$docs = $PSScriptRoot

New-Item -ItemType Directory -Force "$docs/pdf", "$docs/html" | Out-Null

typst compile "$docs/vouch-design.typ" "$docs/pdf/vouch-design.pdf"
typst compile --format html --features html "$docs/vouch-design.typ" "$docs/html/vouch-design.html" 2>$null

# Typst's HTML export emits semantic, unstyled markup; inject the stylesheet.
$css = @'
<style>
@import url('https://fonts.googleapis.com/css2?family=Merriweather:ital,wght@0,400;0,700;1,400&display=swap');
body {
  font-family: "Merriweather", Georgia, serif;
  font-size: 16px;
  line-height: 1.65;
  color: #1a1a1a;
  max-width: 72ch;
  margin: 0 auto;
  padding: 2rem 1.5rem 6rem;
}
h1, h2, h3 { line-height: 1.25; margin: 2.2em 0 0.6em; }
h1 { font-size: 1.8em; }
h2 { font-size: 1.45em; border-bottom: 1px solid #ddd; padding-bottom: 0.3em; }
h3 { font-size: 1.15em; }
code, pre {
  font-family: "Cascadia Mono", Consolas, monospace;
  font-size: 0.88em;
}
code { background: #f4f2ee; padding: 0.1em 0.3em; border-radius: 3px; }
pre {
  background: #f4f2ee;
  padding: 0.9em 1.1em;
  border-radius: 5px;
  overflow-x: auto;
  line-height: 1.45;
}
pre code { background: none; padding: 0; }
table { border-collapse: collapse; margin: 1.2em 0; width: 100%; }
th, td { border: 1px solid #ccc; padding: 0.45em 0.7em; text-align: left; vertical-align: top; }
th { background: #f4f2ee; }
blockquote {
  margin: 1.2em 0;
  padding: 0.6em 1.1em;
  border-left: 4px solid #b8b2a7;
  background: #faf9f7;
  font-style: italic;
}
nav[role="doc-toc"] {
  background: #faf9f7;
  border: 1px solid #e0dcd4;
  border-radius: 5px;
  padding: 1em 1.5em;
  margin: 2em 0;
}
nav[role="doc-toc"] h2 { margin-top: 0; border: none; }
nav[role="doc-toc"] ol { padding-left: 1em; }
a { color: #1a5fb4; }
</style>
'@

$html = "$docs/html/vouch-design.html"
(Get-Content $html -Raw) -replace '</head>', "$css</head>" | Set-Content $html -NoNewline

Write-Output "Built $docs/pdf/vouch-design.pdf and $html"
