<!-- Copied unchanged from TabMail Voice (apps/desktop/native/shared/dictionary in the tabmail-voice repository), where `generate.py` and `requirements.txt` build `words.txt` and `languages.json`. The same files are used by both apps. -->

# Word list for screen terms

A screen term is a name or rare word on screen that the speech model is given so it spells it as
written there (ADR-DESK-038, amended 2026-11-05). A word is ordinary, so no term, when the word list
sees it often enough. This is the list.

- `words.txt`: the words of 42 language lists merged, one line a word, `word<TAB>zipf`, sorted by the
  word's UTF-8 bytes; a word in several lists keeps the most often any of them sees it. The word is in
  the form wordfreq stores it in for its language (below), NFC; `zipf` is how often it is seen, as
  Zipf in tenths (log10 of its frequency per billion words, times ten: `56` is once in about 2,500
  words). Each list keeps only the words it sees at Zipf 2.5 or more (wordfreq's "small" lists, 20 of
  these, start at 3.0), written in its language's scripts. A word is letters and marks, with an
  apostrophe (`don't`), Catalan's middle dot, or a zero-width non-joiner or joiner (Persian's
  `می‌شود`) inside it.
- `languages.json`: for each list, its writings (each the ISO 15924 scripts one word may mix: Japanese
  mixes Han and kana; Serbo-Croatian is written in Latin or in Cyrillic) and how a word is put in the
  form its words are stored in, as wordfreq's `preprocess_text` does for the language: `normal` (NFC or
  NFKC), `letters` (a table in `letters` each letter is replaced through: Serbian's Cyrillic to Latin,
  Chinese's Traditional to Simplified), `marks` (marks and the Arabic tatweel removed), `dotless_i`
  (Turkish's dotted and dotless i) and `under` (s and t with a comma below, `commas`, or a cedilla,
  `cedillas`); then case-folded (`Straße` is `strasse`, a final sigma σ, the ligature `ﬁ` `fi`), NFC,
  and the apostrophe straight. A word on screen is looked up in each form the lists written in its
  script give it.
- `cases.json`: the cases every implementation of the rule runs against the list.
- `generate.py` (with `requirements.txt`): builds `words.txt` and `languages.json`. The output is the
  same on every run.

## Sources and licence

The lists are an adaptation of:

- **wordfreq** 3.1.1 by Robyn Speer (https://github.com/rspeer/wordfreq), data licensed CC BY-SA 4.0.
  Its frequencies come from Wikipedia, OpenSubtitles 2018, SUBTLEX, Google Books Ngrams, the
  Leeds Internet Corpus, the NewsCrawl, Reddit, Twitter and the OSCAR corpus, as its README credits.
  It contains data from the SUBTLEX word lists SUBTLEX-US, SUBTLEX-UK, SUBTLEX-CH, SUBTLEX-DE and
  SUBTLEX-NL, created by Marc Brysbaert et al. and freely available at
  http://crr.ugent.be/programs-data/subtitle-frequencies; as wordfreq's terms ask, we credit their
  authors (the citations as wordfreq's README gives them):
  - Brysbaert, M. & New, B. (2009). Moving beyond Kucera and Francis: A Critical Evaluation of Current
    Word Frequency Norms and the Introduction of a New and Improved Word Frequency Measure for American
    English. Behavior Research Methods, 41 (4), 977-990.
  - Brysbaert, M., Buchmeier, M., Conrad, M., Jacobs, A.M., Bölte, J., & Böhl, A. (2011). The word
    frequency effect: A review of recent developments and implications for the choice of frequency
    estimates in German. Experimental Psychology, 58, 412-424.
  - Cai, Q., & Brysbaert, M. (2010). SUBTLEX-CH: Chinese word and character frequencies based on film
    subtitles. PLoS One, 5(6), e10729.
  - Keuleers, E., Brysbaert, M. & New, B. (2010). SUBTLEX-NL: A new frequency measure for Dutch words
    based on film subtitles. Behavior Research Methods, 42(3), 643-650.
  - van Heuven, W. J., Mandera, P., Keuleers, E., & Brysbaert, M. (2014). SUBTLEX-UK: A new and
    improved word frequency database for British English. The Quarterly Journal of Experimental
    Psychology, 67(6), 1176-1190.
  Its letter tables (Serbian Cyrillic to Latin, Traditional to Simplified Chinese) are copied into
  `languages.json`.
- **FrequencyWords** by Hermit Dave (https://github.com/hermitdave/FrequencyWords), commit
  `525f9b5`, data licensed CC BY-SA 4.0, from OpenSubtitles 2018 (http://www.opensubtitles.org/): the
  Korean list (wordfreq splits Korean into morphemes, FrequencyWords keeps words as written).
- **Unicode CLDR** 48 (https://cldr.unicode.org), Unicode License v3: the letters naming each list's
  scripts.

What we changed: kept the words seen at Zipf 2.5 or more, as Zipf in tenths (Korean's counts turned
into Zipf against the list's total); kept only words written in the language's scripts; dropped tokens
with digits or punctuation; normalized to NFC; merged the lists into one, each word with its highest
Zipf; sorted; copied wordfreq's letter tables and each language's normalization steps into
`languages.json`.

`words.txt` and `languages.json` are licensed **CC BY-SA 4.0**
(https://creativecommons.org/licenses/by-sa/4.0/), as their sources are. The rest of this repository,
`generate.py` included, stays under the MPL 2.0.
