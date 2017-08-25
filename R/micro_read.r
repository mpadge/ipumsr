# This file is part of the Minnesota Population Center's ripums.
# For copyright and licensing information, see the NOTICE and LICENSE files
# in this project's top-level directory, and also on-line at:
#   https://github.com/mnpopcenter/ripums


#' Read data from an IPUMS extract
#'
#' Reads a dataset downloaded from the IPUMS extract system.
#'
#' For IPUMS projects with microdata, it relies on a downloaded
#' DDI codebook and a fixed-width file. Loads the data with
#' value labels (using \code{\link[haven]{labelled}} format)
#' and variable labels.
#'
#' @param ddi Either a filepath to a DDI xml file downloaded from
#'   the website, or a \code{ipums_ddi} object parsed by \code{\link{read_ipums_ddi}}
#' @param vars Names of variables to load. Accepts a character vector of names, or
#'  \code{\link{dplyr_select_style}} conventions. For hierarchical data, the
#'  rectype id variable will be added even if it is not specified.
#' @param n_max The maximum number of records to load.
#' @param data_structure For hierarchical data extract, one of "list" or "long",
#'   to indicate how to structure the data once loaded. "list" data puts a
#'   data.frame for each rectype into a list. "long" data puts all rectypes in
#'   the same data.frame, with \code{NA} values for variables that do not apply
#'   to that particular rectype.
#' @param data_file Specify a directory to look for the data file.
#'   If left empty, it will look in the same directory as the DDI file.
#' @param verbose Logical, indicating whether to print progress information
#'   to console.
#' @examples
#' \dontrun{
#' data <- read_micro("cps_00001.xml")
#' }
#' @family ipums_read
#' @export
read_ipums_micro <- function(
  ddi,
  vars = NULL,
  n_max = -1,
  data_structure = c("list", "long"),
  data_file = NULL,
  verbose = TRUE
) {
  if (is.character(ddi)) ddi <- read_ipums_ddi(ddi)
  if (is.null(data_file)) data_file <- file.path(ddi$file_path, ddi$file_name)
  # Look for zipped versions of the file or csv versions of the file if it doesn't exist
  if (!file.exists(data_file)) {
    file_dat_gz <- file_as_ext(data_file, ".dat.gz")
    file_csv <- file_as_ext(data_file, ".csv")
    file_csv_gz <- file_as_ext(data_file, ".csv.gz")

    if (file.exists(file_dat_gz)) {
      data_file <- file_dat_gz
    } else if (file.exists(file_csv)) {
      data_file <- file_csv
    } else if (file.exists(file_csv_gz)) {
      data_file <- file_csv_gz
    }
  }
  if (verbose) cat(ipums_conditions(ddi))

  vars <- enquo(vars)
  data_structure <- match.arg(data_structure)

  if (ddi$file_type == "hierarchical") {
    out <- read_ipums_hier(ddi, vars, n_max, data_structure, data_file, verbose)
  } else if (ddi$file_type == "rectangular") {
    out <- read_ipums_rect(ddi, vars, n_max, data_file, verbose)
  } else {
    stop(paste0("Don't know how to read ", ddi$file_type, " type file."), call. = FALSE)
  }

  out <- set_ipums_df_attributes(out, ddi)
  out
}

read_ipums_hier <- function(ddi, vars, n_max, data_structure, data_file, verbose) {
  if (ipums_file_ext(data_file) %in% c(".csv", ".csv.gz")) {
    stop("Hierarchical data cannot be read as csv.")
  }
  all_vars <- ddi$var_info

  rec_vinfo <- dplyr::filter(all_vars, .data$var_name == ddi$rectype_idvar)
  if (nrow(rec_vinfo) > 1) stop("Cannot support multiple rectype id variables.", call. = FALSE)

  all_vars <- select_var_rows(all_vars, vars)
  if (!rec_vinfo$var_name %in% all_vars$var_name) {
    if (verbose) message(paste0("Adding rectype id var '", rec_vinfo$var_name, "' to data."))
    all_vars <- dplyr::bind_rows(rec_vinfo, all_vars)
  }

  nonrec_vinfo <- dplyr::filter(all_vars, .data$var_name != ddi$rectype_idvar)
  nonrec_vinfo <- tidyr::unnest_(nonrec_vinfo, "rectypes", .drop = FALSE)

  if (verbose) cat("Reading data...\n")
  lines <- readr::read_lines(
    data_file,
    progress = show_readr_progress(verbose),
    n_max = n_max,
    locale = ipums_locale(ddi$file_encoding)
  )

  if (verbose) cat("Parsing data...\n")
  if (data_structure == "long") {
    nlines <- length(lines)

    # Make a data.frame with all of the variables we will need
    out <- purrr::map(all_vars$var_type, nlines = nlines, function(.x, nlines) {
      switch(
        .x,
        "numeric" = rep(NA_real_, nlines),
        "character" = rep(NA_character_, nlines)
      )
    })
    out <- purrr::set_names(out, all_vars$var_name)
    out <- tibble::as.tibble(out)

    # Add rectype var into our empty data frame
    out[seq_len(nlines), rec_vinfo$var_name] <-
      stringr::str_sub(lines, rec_vinfo$start, rec_vinfo$end)

    # Some projects have numeric RECTYPE in data, even though DDI refers to them by character.
    config <- get_proj_config(ddi$ipums_project)
    if (!is.null(config$rectype_trans)) {
      out$RECTYPE_DDI <- convert_rectype(config$rectype_trans, out[[rec_vinfo$var_name]])
      rec_vinfo$var_name <- "RECTYPE_DDI"
    }

    # Add the rest of the variables
    all_rec_types <- unique(out[[rec_vinfo$var_name]])
    rec_index <- purrr::map(all_rec_types, ~out[[rec_vinfo$var_name]] == .)
    rec_index <- purrr::set_names(rec_index, all_rec_types)

    purrr::pwalk(nonrec_vinfo, function(var_name, start, end, imp_decim, var_type, rectypes, ...) {
      var_data <- stringr::str_sub(lines[rec_index[[rectypes]]], start, end)
      if (var_type == "numeric") {
        var_data <- as.numeric(var_data)
      }
      out[rec_index[[rectypes]], var_name] <<- var_data
    })

    out <- set_ipums_var_attributes(out, all_vars)
  } else if (data_structure == "list") {
    # Determine rectypes
    rec_type <- stringr::str_sub(lines, rec_vinfo$start, rec_vinfo$end)

    # Some projects have numeric RECTYPE in data, even though DDI refers to them by character.
    config <- get_proj_config(ddi$ipums_project)
    if (!is.null(config$rectype_trans)) {
      rec_type <- convert_rectype(config$rectype_trans, rec_type)
    }

    rec_types_in_extract <- dplyr::intersect(rec_vinfo$rectypes[[1]], unique(rec_type))

    # Make a data.frame for each rectype
    out <- purrr::map(rec_types_in_extract, function(rt) {
      vars_in_rec <- nonrec_vinfo[purrr::map_lgl(nonrec_vinfo$rectypes, ~rt %in% .), ]
      lines_in_rec <- lines[rec_type == rt]

      nlines_rt <- length(lines_in_rec)

      out_rt <- purrr::map(vars_in_rec$var_type, nlines = nlines_rt, function(.x, nlines) {
        switch(
          .x,
          "numeric" = rep(NA_real_, nlines),
          "character" = rep(NA_character_, nlines)
        )
      })
      out_rt <- purrr::set_names(out_rt, vars_in_rec$var_name)
      out_rt <- tibble::as.tibble(out_rt)


      # Add in the variables
      purrr::pwalk(vars_in_rec, function(var_name, start, end, imp_decim, var_type, rectypes, ...) {
        var_data <- stringr::str_sub(lines_in_rec, start, end)
        if (var_type == "numeric") {
          var_data <- as.numeric(var_data)
        }
        out_rt[[var_name]] <<- var_data
      })

      out_rt <- set_ipums_var_attributes(out_rt, vars_in_rec)
    })
    names(out) <- rec_types_in_extract
  }
  out
}

read_ipums_rect <- function(ddi, vars, n_max, data_file, verbose) {
  all_vars <- select_var_rows(ddi$var_info, vars)

  col_types <- purrr::map(all_vars$var_type, function(x) {
    if (x == "numeric") out <- readr::col_double()
    else if(x == "character") out <- readr::col_character()
    out
  })
  names(col_types) <- all_vars$var_name
  col_types <- do.call(readr::cols, col_types)

  col_positions <- readr::fwf_positions(
    start = all_vars$start,
    end = all_vars$end,
    col_names = all_vars$var_name
  )

  is_fwf <- ipums_file_ext(data_file) %in% c(".dat", ".dat.gz")
  is_csv <- ipums_file_ext(data_file) %in% c(".csv", ".csv.gz")

  if (is_fwf) {
    out <- readr::read_fwf(
      data_file,
      col_positions,
      col_types,
      n_max = n_max,
      locale = ipums_locale(ddi$file_encoding),
      progress = show_readr_progress(verbose)
    )
  } else if (is_csv) {
    out <- readr::read_csv(
      data_file,
      col_types = col_types,
      n_max = n_max,
      locale = ipums_locale(ddi$file_encoding),
      progress = show_readr_progress(verbose)
    )
  } else {
    stop("Unrecognized file type.")
  }
  out <- set_ipums_var_attributes(out, all_vars)

  out
}
