<!-- Copied from TabMail Voice (apps/desktop/native/shared/dictionary in the tabmail-voice repository), with this note added at the top. Only words.txt, languages.json and this README are vendored here; the generator (`generate.py`, `requirements.txt`), its tests and `cases.json` stay in the Voice repository, and the shared cases are kept in the app's test fixtures. The same words.txt and languages.json are used by both apps. -->

# Word list for screen terms

A screen term is a name or rare word on screen that the speech model is given so it spells it as
written there (ADR-DESK-038, amended 2026-11-05 and 2026-11-06). A word is ordinary, so no term, when the word list
sees it often enough. This is the list.

- `words.txt`: the words of 41 language lists merged, one line a word, `word<TAB>zipf`, sorted by the
  word's UTF-8 bytes; a word in several lists keeps the most often any of them sees it. The word is in
  the form wordfreq's code puts a word in for its language (below), NFC; `zipf` is how often it is
  seen, as Zipf in tenths (log10 of its frequency per billion words, times ten: `56` is once in about
  2,500 words). Each list keeps only the words it sees at Zipf 2.5 or more, written in its language's
  scripts. A word is letters and marks, with an apostrophe inside it (`don't`). FrequencyWords
  splits words at Catalan's middle dot and the zero-width non-joiner and joiner, so its lists hold
  only their parts; a hyphenated word it lists is dropped. The lookup sees any of these words as its
  least seen part. Japanese has
  no list: FrequencyWords' Japanese list holds
  word stems without their kana, so every Japanese word would look rare.
- `languages.json`: for each list, its writings (each the ISO 15924 scripts one word may mix; Serbo-Croatian is
  written in Latin or in Cyrillic) and how a word is put in the form its words are stored in, as wordfreq's
  `preprocess_text` does for the language: `normal` (NFC or NFKC), `letters` (a table in `letters` each
  letter is replaced through: Serbian's Cyrillic to Latin, Chinese's Traditional to Simplified),
  `marks` (marks and the Arabic tatweel removed), `dotless_i` (Turkish's dotted and dotless i) and
  `under` (s and t with a comma below, `commas`, or a cedilla, `cedillas`); then case-folded (`Straße`
  is `strasse`, a final sigma σ, the ligature `ﬁ` `fi`), NFC, and the apostrophe straight. A word on
  screen is looked up in each form the lists written in its script give it.
- `cases.json`: the cases every implementation of the rule runs against the list.
- `generate.py` (with `requirements.txt`): builds `words.txt` and `languages.json`. The output is the
  same on every run.
- `test_generate.py`: the generator's tests, offline (every download answered from fixtures): each
  list's sources counted together, counts added up after each word is put in its list's form, the
  Zipf floor and scripts, Japanese's missing list, and the files written. Run with the pinned packages
  from this folder: `python3 -m venv /tmp/word-lists && /tmp/word-lists/bin/pip install -r
  requirements.txt`, then `/tmp/word-lists/bin/python -m unittest test_generate`.

## Sources and licence

The word list is adapted from:

- **FrequencyWords** by Hermit Dave (https://github.com/hermitdave/FrequencyWords), commit
  `525f9b560de45753a5ea01069454e72e9aa541c6`, Copyright (c) 2016 Hermit Dave, content licensed
  CC BY-SA 4.0 (its code MIT): word counts built from the OpenSubtitles 2018 corpus
  (http://www.opensubtitles.org/, via OPUS, http://opus.nlpl.eu/OpenSubtitles2018.php). As OPUS asks,
  the corpus is cited: P. Lison and J. Tiedemann (2016), "OpenSubtitles2016: Extracting Large Parallel
  Corpora from Movie and TV Subtitles", in Proceedings of the 10th International Conference on
  Language Resources and Evaluation (LREC 2016). Filipino is its Tagalog list, Norwegian Bokmål its
  Norwegian, Portuguese its Portuguese and Brazilian Portuguese together, Serbo-Croatian its Croatian,
  Serbian and Bosnian together, and Chinese its Simplified and Traditional lists together.

The lists' catalog, `languages.json`, is adapted from:

- **wordfreq** 3.1.1 by Robyn Speer (https://github.com/rspeer/wordfreq), Copyright 2022 Robyn Speer,
  code licensed Apache License 2.0, data licensed CC BY-SA 4.0. Its letter tables are copied into
  `languages.json`: Serbian Cyrillic to Latin (from its code), and Traditional to Simplified Chinese
  (its data, made with OpenCC, https://github.com/BYVoid/OpenCC, Apache License 2.0). Each list's
  normalization steps are its language info. Its code also puts each word of the lists in its list's
  form. Its word frequencies are not used. wordfreq contains data from the SUBTLEX word lists, created
  by Marc Brysbaert et al. (http://crr.ugent.be/programs-data/subtitle-frequencies); as wordfreq's terms
  ask, we credit their authors:
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
- **Unicode CLDR** 48 (https://cldr.unicode.org, data from https://github.com/unicode-org/cldr-json),
  Unicode License v3 (its notice is below): the letters naming each list's scripts.

What we changed: put each word in its list's form and added up the counts of words that share it;
turned the counts into Zipf in tenths against the list's total; kept the words seen at Zipf 2.5 or
more; kept only words written in the language's scripts; dropped tokens with digits or punctuation;
normalized to NFC; merged the lists into one, each word with its highest Zipf; sorted; wrote each
language's writings (from CLDR's letters), its normalization steps and wordfreq's letter tables into
`languages.json`.

`words.txt` and `languages.json` are licensed **CC BY-SA 4.0**
(https://creativecommons.org/licenses/by-sa/4.0/), as their sources are. They are provided as is,
without warranties of any kind; see sections 5 and 6 of the licence
(https://creativecommons.org/licenses/by-sa/4.0/legalcode). The rest of this repository, `generate.py`
included, stays under the MPL 2.0.

### Unicode License v3 (CLDR)

```text
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 2015-2024 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.

SPDX-License-Identifier: Unicode-3.0
```
