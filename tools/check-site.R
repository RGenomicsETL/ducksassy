#!/usr/bin/env Rscript
# Every local page, asset and fragment must resolve within the generated site.
files <- list.files("site", pattern = "\\.html$", recursive = TRUE, full.names = TRUE)
stopifnot(length(files) > 0L)
landing <- xml2::read_html(file.path("site", "index.html"))
landing_title <- xml2::xml_text(xml2::xml_find_all(landing, "//div[contains(@class, 'frontmatter')]//h1"))
stopifnot(identical(landing_title, "ducksassy"))
for (file in files) {
  page <- xml2::read_html(file)
  frontmatter <- xml2::xml_find_all(page, "//div[contains(@class, 'frontmatter')]")
  if (length(frontmatter) == 1L) {
    stopifnot(length(xml2::xml_find_all(frontmatter, ".//h1")) == 1L,
              length(xml2::xml_find_all(page, "//div[contains(@class, 'body')]/h1")) == 0L)
  }
  nodes <- xml2::xml_find_all(page, "//*[@href or @src]")
  links <- unique(na.omit(c(xml2::xml_attr(nodes, "href"), xml2::xml_attr(nodes, "src"))))
  links <- links[!grepl("^([[:alpha:]][[:alnum:]+.-]*:|//)", links)]
  for (link in links) {
    path <- URLdecode(sub("[?#].*$", "", link))
    target <- if (!nzchar(path)) file else file.path(dirname(file), path)
    if (dir.exists(target)) target <- file.path(target, "index.html")
    if (!file.exists(target)) stop(file, ": missing link ", link)
    if (grepl("#.+$", link) && grepl("\\.html$", target)) {
      fragment <- URLdecode(sub("^.*#", "", link))
      ids <- xml2::xml_attr(xml2::xml_find_all(xml2::read_html(target), "//*[@id]"), "id")
      if (!fragment %in% ids) stop(file, ": missing fragment ", link)
    }
  }
}
message("Verified local links and fragments in ", length(files), " HTML pages")
