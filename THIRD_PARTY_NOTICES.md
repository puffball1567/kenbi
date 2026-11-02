# Third-party material

> **Read this first.** None of the projects listed below is a dependency of kenbi or part of what
> kenbi does: kenbi does not link, load or bundle any of them. This file is kept as a precaution.
> The repository contains a few test cases taken from a public-domain test suite, and short
> quotations of other projects' code or identifiers in documentation and examples; most of the
> attributions below are given although no license requires them. Why each entry is here, and what
> it does and does not imply, is explained in
> [docs/third_party_material.md](docs/third_party_material.md).

kenbi itself is licensed under the Apache License 2.0 ([LICENSE.md](LICENSE.md)). When third-party
material is added, it is recorded here in the same commit.

## Test cases taken from a public test suite

### Juliet Test Suite for C/C++, version 1.3

- Source: NIST Software Assurance Reference Dataset (SARD), <https://samate.nist.gov/SARD/>,
  obtained through the mirror <https://github.com/arichardson/juliet-test-suite-c>
  (commit `f88433e3443648a17671398797a04ea1f8e1a274`).
- License: not subject to copyright protection in the United States (17 USC 105); elsewhere made
  available under CC0 1.0 Universal. No attribution is required; it is recorded here for provenance.
- Files copied unmodified from the suite's `testcases/` directory:
  - `demo/juliet/CWE401_Memory_Leak__char_malloc_01.c`
  - `demo/juliet/CWE401_Memory_Leak__char_malloc_41.c`
  - `demo/juliet/CWE415_Double_Free__malloc_free_char_01.c`
  - `demo/juliet/CWE415_Double_Free__malloc_free_char_22a.c`
  - `demo/juliet/CWE415_Double_Free__malloc_free_char_22b.c`
  - `demo/juliet/CWE415_Double_Free__malloc_free_char_41.c`
  - `demo/juliet/CWE416_Use_After_Free__malloc_free_char_01.c`
  - `demo/juliet/CWE590_Free_Memory_Not_on_Heap__free_char_declare_01.c`
  - `demo/juliet/CWE761_Free_Pointer_Not_at_Start_of_Buffer__char_fixed_string_01.c`
- Files copied from the suite and edited: the files of the same names in `demo/juliet_annotated/`
  (all of the above except `..._22b.c`). kenbi annotations and an explanatory comment are added,
  some of the suite's comments are shortened or removed, a prototype of the suite's `printLine` is
  added, and the optional `main` (the `INCLUDEMAIN` block) is removed. The code is otherwise
  unchanged.
- Derived from those files: the rewrites of the same names in `demo/juliet_rewritten/` (all of the
  above except `..._22b.c`), and the testcase text embedded in `mcp/src/generated/findings.ts`,
  which `demo/gen_mcp_from_corpus.py` generates from the `demo/juliet*` corpus.
- The other files in `demo/juliet*` follow the suite's naming scheme but are written for kenbi.

## Projects quoted in documentation and examples

Each entry below is a short quotation of another project's code, or of its identifiers, inside
kenbi's documentation, comments, demonstrations or test inputs. kenbi is not affiliated with or
endorsed by any of these projects or their authors, and does not claim to have created them. The
copies under [licenses/](licenses/) are unmodified and were taken from the source named in each
entry.

### ImageMagick

- Copyright © 1999 ImageMagick Studio LLC, a non-profit organization dedicated to making software
  imaging solutions freely available. Licensed under the ImageMagick License,
  <https://imagemagick.org/license/>; copy: [licenses/ImageMagick-LICENSE.txt](licenses/ImageMagick-LICENSE.txt),
  from <https://github.com/ImageMagick/ImageMagick> commit `66f171691a2ba827c0cd549058eb321a385b3b79`.
- The ImageMagick name and marks are owned by ImageMagick Studio LLC; their use here only identifies
  the software being described.
- Where quoted: lines of ImageMagick source shown in `demo/imagemagick/README.md` to explain
  findings; short expressions and function names in the comments and annotation lines of
  `demo/imagemagick/*.h`, the function names `demo/imagemagick/audit.py` searches for, and the
  README in every language; and function names and short expressions naming the code shape a test
  or rule was made for, in comments in `src/`, `mcp/src/annotations.ts` and `tests/c/t197`,
  `t199`, `t202`, `t208`, `t211`–`t213`, `t215`, `t219`–`t223`, `t225` and `t230`. The test
  inputs are written for kenbi; they reproduce the shape of the code under their own names.

### zlib

- Copyright © 1995-2017 Jean-loup Gailly and Mark Adler. Licensed under the zlib License; copy:
  [licenses/zlib-LICENSE.txt](licenses/zlib-LICENSE.txt), from the notice in `zlib.h` of zlib 1.2.11.
- Where quoted: the expansion of zlib's `ZALLOC` macro and the names of its allocator fields, in
  the comments of `demo/zlib/README.md`, `demo/zlib/kenbi_zlib_mem.h`,
  `tests/c/t204_injected_allocator.c` and `src/frontend_c.nim`. The annotation header names
  zlib's allocator fields; it is not an altered version of zlib.

### QuickJS (quickjs-ng)

- Copyright © 2017-2026 Fabrice Bellard, © 2017-2024 Charlie Gordon, © 2023-2026 Ben Noordhuis,
  © 2023-2026 Saúl Ibarra Corretgé. Licensed under the MIT License; copy:
  [licenses/QuickJS-LICENSE.txt](licenses/QuickJS-LICENSE.txt), from
  <https://github.com/quickjs-ng/quickjs> commit `60984dc07cbb6b7885303b9542944b114203e918`.
- Where quoted: QuickJS function names and a short call expression that name the code shape a
  test or example was made for, in comments in `tests/c/t151`, `t152` and `t154`, and in
  `demo/juliet*/CWE125_Out_of_Bounds_Read__lookahead_01.c` and the text generated from it
  (`mcp/src/generated/findings.ts`).

### jsmn

- Copyright © 2010 Serge A. Zaitsev. Licensed under the MIT License; copy:
  [licenses/jsmn-LICENSE.txt](licenses/jsmn-LICENSE.txt), from <https://github.com/zserge/jsmn>
  commit `25647e692c7906b96ffd2b05ca54c097948e879c`.
- Where quoted: jsmn's field names and the relations between them (for example
  `toksuper < toknext <= num_tokens`) in comments in `src/`, `tests/c/t122`–`t132` and
  `mcp/src/annotations.ts`, and in the README in every language.

### curl

- Copyright © 1996-2026 Daniel Stenberg and many contributors. Licensed under the curl license;
  copy: [licenses/curl-COPYING.txt](licenses/curl-COPYING.txt), from <https://github.com/curl/curl>
  commit `2910040880e6cd48be9ccc5e823b8381c260c0d2`.
- Where quoted: curl's function and type names and short expressions in the minimal reproductions of
  CVE-2016-8619 and CVE-2018-16840: `demo/juliet*/CWE415_Double_Free__curl_krb5_cve_2016_8619_02.c`,
  `demo/juliet*/CWE416_Use_After_Free__curl_cve_2018_16840_03.c`, and the text generated from them
  (`demo/juliet/manifest.json`, `mcp/src/generated/*.ts`); the CVE number and `Curl_close` are
  named in a comment in `mcp/test/e2e.test.mjs`.

### Ring-Buffer

- Copyright © 2014 Anders Kalør. Licensed under the MIT License; copy:
  [licenses/Ring-Buffer-LICENSE.txt](licenses/Ring-Buffer-LICENSE.txt), from
  <https://github.com/AndersKaloer/Ring-Buffer> commit `8de8fff55a0baee4fef2a1c6a82d258a27c3c0ba`.
- Where quoted: the project's name and its field names `buffer` and `buffer_mask`, naming the
  power-of-two mask idiom a rule was made for, in comments in `src/` and
  `tests/c/t133_spatial_mask_ring_buffer.c`. The test input is written for kenbi.

### OpenSSL

- Copyright © 1998-2016 The OpenSSL Project; Copyright © 1995-1998 Eric Young. Licensed under the
  OpenSSL License and the original SSLeay License; copy:
  [licenses/OpenSSL-1.0.1-LICENSE.txt](licenses/OpenSSL-1.0.1-LICENSE.txt), from
  <https://github.com/openssl/openssl> branch `OpenSSL_1_0_1-stable`, commit
  `4675a56a3ce2bef715386e45036426c8a4329d39`.
- Where quoted: the minimal reproduction of CVE-2014-0160 (Heartbleed),
  `demo/juliet*/CWE125_Out_of_Bounds_Read__heartbleed_cve_2014_0160_08.c`, reproduces the function
  name `tls1_process_heartbeat`, its variable names and the line `memcpy(bp, pl, payload);` of
  OpenSSL 1.0.1; the same identifiers appear in the text generated from it
  (`demo/juliet/manifest.json`, `mcp/src/generated/*.ts`), in comments in `src/frontend_c.nim` and
  `tests/c/t158_memcpy_source_read.c`, and as the CVE number in `mcp/test/e2e.test.mjs`.
- Acknowledgment: the reproduced line and identifiers are software developed by the OpenSSL Project
  for use in the OpenSSL Toolkit (<http://www.openssl.org/>). kenbi includes no other OpenSSL
  software, and no cryptographic software written by Eric Young or software written by Tim Hudson.

## Not included

- The projects kenbi has been measured against (the Juliet suite as a whole, ImageMagick, QuickJS,
  jsmn, Ring-Buffer) are obtained separately and analysed in place; their source is not part of this repository
  beyond the material listed above.
- libclang (LLVM project, Apache License 2.0 with LLVM Exceptions) is loaded at run time from the
  system; it is not bundled.
- The MCP server's npm dependencies are installed by `npm ci` and are not committed:
  `@modelcontextprotocol/sdk` (MIT), `zod` (MIT), and for development `typescript` (Apache-2.0)
  and `@types/node` (MIT).
