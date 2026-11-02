# Third-party material in this repository

This page explains why [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) lists other projects,
and what those entries do and do not mean. It describes how this project handles such material; it
is not legal advice.

## In short

- kenbi is licensed under the Apache License 2.0 ([LICENSE.md](../LICENSE.md)).
- kenbi does not depend on, link, load or bundle any of the projects in the notices. None of them is
  part of what kenbi does; removing every one of them would not change kenbi's behaviour.
- The only third-party files in the repository are nine test cases from the Juliet Test Suite and
  versions of them edited for the demonstration (annotations and comments added, the optional
  `main` removed). Juliet is in the public domain in the United States and
  under CC0 1.0 elsewhere, so it imposes no conditions.
- Every other entry is there because the documentation, examples or tests quote a line, an
  expression or some identifiers from another project. Those entries are kept as a precaution:
  attribution is given even where the quotation is too short for any license to require it.

## What the material is, and why it is here

| Kind | Where | Why |
|---|---|---|
| Test cases from the Juliet Test Suite | `demo/juliet`, `demo/juliet_annotated`, `demo/juliet_rewritten`, and text generated from them in `mcp/src/generated/` | The three-state demonstration (unannotated, annotated, rewritten) is built on recognised CWE test cases. Most of the corpus is written for kenbi in the same style; nine files are taken from the suite as they are. |
| Lines of real code shown to explain findings | `demo/imagemagick/README.md` | When kenbi is measured on a real project, the write-up shows the lines a finding is about, so that a reader can check it. |
| Minimal reproductions of published vulnerabilities | the `*_cve_*` files in `demo/juliet*`, and what is generated from them | A few lines that reproduce the mechanism of OpenSSL CVE-2014-0160 and curl CVE-2016-8619 / CVE-2018-16840, so that the corpus shows kenbi on the shape of a real bug. They are written for kenbi, but keep the original function and variable names, and the Heartbleed one keeps the original copy line, so that the reproduction can be recognised. |
| Annotation headers for projects kenbi is applied to | `demo/imagemagick/*.h`, `demo/zlib/` | They let kenbi analyse ImageMagick and zlib without editing them, by naming their functions and fields. They contain no code of those projects; their comments quote a few short expressions. |
| Comments naming code shapes | `src/`, `tests/`, `demo/juliet*`, `mcp/src/annotations.ts`, the READMEs | Comments that explain a rule by the real-world code it was made for (for example jsmn's `toksuper < toknext <= num_tokens`, an ImageMagick destructor, Ring-Buffer's `buffer_mask`, or the QuickJS function a test reproduces the shape of). The test inputs around them are written for kenbi. Comments are not compiled into kenbi. |

## What the attributions do and do not mean

- **Not dependencies.** Building and running kenbi needs only Nim, libclang (loaded from the system
  at run time) and, for the MCP server, the npm packages listed in `mcp/package.json`, which are
  installed separately. None of the quoted projects is among them.
- **Nothing quoted reaches the kenbi executable.** The quotations sit in documentation, comments,
  demonstration files and test inputs. The kenbi executable contains kenbi's own code and the Nim
  runtime and standard library (MIT); if kenbi executables are distributed, the Nim notice belongs in
  that distribution.
- **No endorsement.** Naming a project, its authors or its marks only identifies the code being
  described. kenbi is not affiliated with or endorsed by any of them.
- **Precautionary.** For each quoted project the notices give the copyright holders and an unmodified
  copy of its license under [licenses/](../licenses/), taken from the commit recorded there. This is
  the attribution each license asks for when its software is redistributed, given here even though
  only short quotations are involved.

## OpenSSL

The OpenSSL 1.0.1 license (OpenSSL License with the original SSLeay License) asks for an
acknowledgment of the OpenSSL Project, and forbids using the names "OpenSSL Toolkit" and "OpenSSL
Project" to endorse or promote products, or calling derived products "OpenSSL". The notices therefore
acknowledge the OpenSSL Project for the reproduced line and identifiers only, and state that kenbi
contains no other OpenSSL software. The SSLeay acknowledgments (cryptographic software by Eric Young,
software by Tim Hudson) concern code kenbi does not contain. Current OpenSSL releases (3.0 and later)
are under the Apache License 2.0; the 1.0.1 license is used because the reproduced code is from that
release.

## Redistributing this repository

If you redistribute the repository, or the demonstrations and tests on their own, keep
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and [licenses/](../licenses/) with them. Nothing
further is needed for the Juliet files.

## Adding material

Before material from another project is added, its license and redistribution terms are checked. It
is then recorded in THIRD_PARTY_NOTICES.md in the same commit: source and version, license, the files
that contain it, and the attribution the license asks for — given even when the license would not
require it for the amount quoted — with an unmodified copy of the license under `licenses/`.
