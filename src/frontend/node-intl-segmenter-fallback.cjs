'use strict';

// Fedora's Node 24.13.1 can segfault in V8's Intl.Segmenter path. The Angular
// CLI dependencies use it for terminal string-width calculations, so a small
// JavaScript approximation is enough to keep the build tooling out of native
// code that is crashing.
(function installIntlSegmenterFallback() {
  if (!globalThis.Intl || typeof globalThis.Intl !== 'object') {
    return;
  }

  if (typeof globalThis.Intl.Segmenter !== 'function') {
    return;
  }

  const MARK_RE = /\p{Mark}/u;
  const WORD_RE = /[\p{Letter}\p{Number}]/u;

  function isVariationSelector(char) {
    const codePoint = char.codePointAt(0);
    return (codePoint >= 0xfe00 && codePoint <= 0xfe0f)
      || (codePoint >= 0xe0100 && codePoint <= 0xe01ef);
  }

  function isEmojiModifier(char) {
    const codePoint = char.codePointAt(0);
    return codePoint >= 0x1f3fb && codePoint <= 0x1f3ff;
  }

  function isRegionalIndicator(char) {
    const codePoint = char.codePointAt(0);
    return codePoint >= 0x1f1e6 && codePoint <= 0x1f1ff;
  }

  function isAttachedToPrevious(char) {
    return char === '\u200d'
      || MARK_RE.test(char)
      || isVariationSelector(char)
      || isEmojiModifier(char);
  }

  function makeRecord(segment, index, input, granularity) {
    const record = { segment, index, input };
    if (granularity === 'word') {
      record.isWordLike = WORD_RE.test(segment);
    }
    return record;
  }

  function splitGraphemes(input, granularity) {
    const records = [];
    let segment = '';
    let segmentIndex = 0;
    let offset = 0;
    let joinNext = false;
    let regionalRun = 0;

    function pushSegment() {
      if (segment.length === 0) {
        return;
      }

      records.push(makeRecord(segment, segmentIndex, input, granularity));
    }

    for (const char of Array.from(input)) {
      const regional = isRegionalIndicator(char);
      const attach = segment.length > 0
        && (joinNext
          || isAttachedToPrevious(char)
          || (regional && regionalRun % 2 === 1));

      if (!attach) {
        pushSegment();
        segment = '';
        segmentIndex = offset;
        regionalRun = 0;
      }

      segment += char;
      offset += char.length;
      joinNext = char === '\u200d';
      regionalRun = regional ? regionalRun + 1 : 0;
    }

    pushSegment();
    return records;
  }

  class FallbackSegments {
    constructor(records) {
      this.records = records;
    }

    containing(index) {
      const numericIndex = Number(index);
      if (!Number.isFinite(numericIndex)) {
        return undefined;
      }

      return this.records.find((record) => {
        return numericIndex >= record.index
          && numericIndex < record.index + record.segment.length;
      });
    }

    [Symbol.iterator]() {
      return this.records[Symbol.iterator]();
    }
  }

  class FallbackSegmenter {
    constructor(locales, options = {}) {
      const localeList = locales === undefined
        ? []
        : Array.isArray(locales)
          ? locales
          : [locales];

      this.locale = localeList.length > 0 ? String(localeList[0]) : 'en-US';
      this.granularity = ['grapheme', 'word', 'sentence'].includes(options.granularity)
        ? options.granularity
        : 'grapheme';
    }

    segment(input) {
      return new FallbackSegments(splitGraphemes(String(input), this.granularity));
    }

    resolvedOptions() {
      return {
        locale: this.locale,
        granularity: this.granularity,
      };
    }

    static supportedLocalesOf(locales) {
      if (locales === undefined) {
        return [];
      }

      return (Array.isArray(locales) ? locales : [locales]).map(String);
    }
  }

  Object.defineProperty(globalThis.Intl, 'Segmenter', {
    configurable: true,
    writable: true,
    value: FallbackSegmenter,
  });
}());
