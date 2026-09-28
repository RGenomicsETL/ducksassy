#!/usr/bin/env Rscript
# Render committed results without executing R or SQL examples.
root <- normalizePath(".", winslash = "/", mustWork = TRUE)
destination <- file.path(root, "site")
pkgdown::build_site("r/Rducksassy", examples = FALSE, new_process = FALSE,
                    install = FALSE, preview = FALSE)

reports <- sort(list.files("benchmarks", pattern = "\\.md$", full.names = TRUE))
sources <- c("README.md", reports, "docs/v1-host.md", "docs/functions.md")
outputs <- c("index.html", sub("\\.md$", ".html", sources[-1L]))
names(outputs) <- normalizePath(sources, winslash = "/", mustWork = TRUE)
header <- readLines("tools/landing-header.html", warn = FALSE)
css <- normalizePath("tools/landing.css", winslash = "/", mustWork = TRUE)

for (i in seq_along(sources)) {
  source <- sources[[i]]
  output <- file.path(destination, outputs[[i]])
  dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
  text <- readLines(source, warn = FALSE, encoding = "UTF-8")
  text <- text[!grepl("^<!-- README.md is generated", text)]
  atx <- which(startsWith(text, "# "))
  setext <- grep("^=+\\s*$", text) - 1L
  setext <- setext[setext >= 1L]
  first <- suppressWarnings(min(c(atx, setext)))
  title <- tools::file_path_sans_ext(basename(source))
  if (is.finite(first)) {
    if (first %in% atx) {
      title <- substring(text[[first]], 3L)
      drop <- first
    } else {
      title <- text[[first]]
      drop <- c(first, first + 1L)
    }
    text <- text[-drop]
  }
  prefix <- if (dirname(outputs[[i]]) == ".") "" else "../"
  litedown::mark(text = c("---", paste0("title: ", trimws(title)), "output: html", "---", text),
                 output = output, options = list(toc = TRUE),
                 meta = list(css = c("@default@1.14.69", "@article@1.14.69",
                                      "@site@1.14.69", css),
                             include_before = I(gsub("@ROOT@", prefix, header, fixed = TRUE))))

  # Match GitHub's heading fragments used by the committed Markdown reports.
  page <- xml2::read_html(output)
  title <- xml2::xml_find_first(page, "//title")
  xml2::xml_text(title) <- xml2::xml_text(xml2::xml_find_first(page, "//h1"))
  headings <- xml2::xml_find_all(page, "//*[self::h1 or self::h2 or self::h3 or self::h4 or self::h5 or self::h6][@id]")
  ids <- xml2::xml_attr(headings, "id")
  fragments <- sub("^[^:]+:", "", ids)
  xml2::xml_attr(headings, "id") <- fragments
  toc <- xml2::xml_find_all(page, "//a[starts-with(@href, '#')]")
  hrefs <- xml2::xml_attr(toc, "href")
  matches <- match(hrefs, paste0("#", ids))
  xml2::xml_attr(toc[!is.na(matches)], "href") <- paste0("#", fragments[matches[!is.na(matches)]])

  # Resolve Markdown source links to rendered pages or repository source files.
  links <- xml2::xml_find_all(page, "//a[@href]")
  for (link in links) {
    href <- xml2::xml_attr(link, "href")
    if (grepl("^([[:alpha:]][[:alnum:]+.-]*:|/|#)", href)) next
    if (grepl("\\.html($|#)", href)) next
    path <- sub("#.*$", "", href)
    fragment <- substring(href, nchar(path) + 1L)
    target <- normalizePath(file.path(dirname(source), path), winslash = "/", mustWork = TRUE)
    if (target %in% names(outputs)) {
      href <- paste0(fs::path_rel(file.path(destination, outputs[[target]]), dirname(output)), fragment)
    } else {
      href <- paste0("https://github.com/RGenomicsETL/ducksassy/blob/main/",
                     fs::path_rel(target, root), fragment)
    }
    xml2::xml_attr(link, "href") <- href
  }
  xml2::write_html(page, output)
}

index <- paste0("- [", tools::file_path_sans_ext(basename(reports)),
                "](", sub("\\.md$", ".html", basename(reports)), ")")
litedown::mark(text = c("---", "title: Benchmarks", "output: html", "---", index),
               output = file.path(destination, "benchmarks", "index.html"),
               meta = list(css = c("@default@1.14.69", "@article@1.14.69",
                                    "@site@1.14.69", css),
                           include_before = I(gsub("@ROOT@", "../", header, fixed = TRUE))))
source("tools/check-site.R")
