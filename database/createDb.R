
library(cli)
library(duckdb)
library(glue)
library(DBI)

path <- '/Users/martics/Documents/'
datasetName <- "synthea-covid19-10k"

fileName <- file.path(path, glue::glue("{datasetName}.zip"))

# download data
# pb <- cli::cli_progress_bar(format = "[:bar] :percent :elapsed", type = "download")
# options(timeout = 5000)
# download.file(
#   url = glue::glue("https://example-data.ohdsi.dev/{datasetName}.zip"),
#   destfile = fileName,
#   mode = "wb", method = "auto", quiet = FALSE,
#   extra = list(progressfunction = function(downloaded, total) {
#     progress <- min(1, downloaded/total)
#     cli::cli_progress_update(id = pb, set = progress)
#   })
# )

# un zip data
tempFileLocation <- tempdir()
unzip(zipfile = fileName, exdir = tempFileLocation)
dataFiles <- list.files(path = file.path(tempFileLocation, datasetName), pattern = "*.parquet", full.names = TRUE)

# temporary duckdb
tmpDatabase <- tempfile(fileext = ".duckdb")
con <- DBI::dbConnect(duckdb::duckdb(), tmpDatabase)

# copy tables
specs <- CDMConnector:::spec_cdm_field[["5.3"]] |>
  dplyr::mutate(cdmDatatype = dplyr::if_else(
    .data$cdmDatatype == "varchar(max)", "varchar(2000)", .data$cdmDatatype))
purrr::map(dataFiles, \(x) {
  tableName <- tools::file_path_sans_ext(basename(x))
  fields <- specs$cdmDatatype[specs$cdmTableName == tableName]
  if (length(fields) > 0) {
    names(fields) <- specs$cdmFieldName[specs$cdmTableName == tableName]
    DBI::dbCreateTable(
      conn = con,
      name = DBI::Id(schema = "main", table = tableName),
      fields = fields
    )
    DBI::dbExecute(
      conn = con,
      statement = glue::glue("INSERT INTO main.{tableName} SELECT * FROM parquet_scan('{x}');")
    )
  } else {
    print("empty table: {tableName}" |> glue::glue())
  }
  NULL
}) |>
  invisible()

DBI::dbDisconnect(con, shutdown = TRUE)
file.copy(from = tmpDatabase, to = file.path(path, glue::glue("{datasetName}.duckdb")), overwrite = TRUE)
unlink(tempFileLocation, recursive = TRUE)

con <- DBI::dbConnect(duckdb::duckdb(), file.path(path, glue::glue("{datasetName}.duckdb")))
cdm <- CDMConnector::cdmFromCon(con = con, cdmSchema = "main", writeSchema = "main", cdmName = "my db")

names(cdm) |>
  rlang::set_names() |>
  purrr::map_int(\(x) cdm[[x]] |> dplyr::tally() |> dplyr::pull())

selCol <- function(x, col) {
  purrr::map(col, \(column) {
    x |>
      dplyr::select("concept_id" = dplyr::all_of(column)) |>
      dplyr::distinct() |>
      dplyr::pull() |>
      as.integer()
  }) |>
    unlist() |>
    unique()
}

concepts <- c(
  cdm$condition_occurrence |>
    selCol("condition_concept_id"),
  cdm$drug_exposure |>
    selCol("drug_concept_id"),
  cdm$procedure_occurrence |>
    selCol("procedure_concept_id"),
  cdm$device_exposure |>
    selCol("device_concept_id"),
  cdm$drug_era |>
    selCol("drug_concept_id")
) |>
  unique()

cdm$concept_synonym <- cdm$concept_synonym |>
  dplyr::filter(concept_id == 0L)

toFilter <- list(
  concept = "concept_id",
  concept_relationship = c("concept_id_1", "concept_id_2"),
  concept_ancestor = c("ancestor_concept_id", "descendant_concept_id"),
  drug_strength = c("drug_concept_id", "ingredient_concept_id")
)

extractConcepts <- function(con, x, cols) {
  x |>
    dplyr::filter(
      .data[[cols[1]]] %in% .env$con | .data[[cols[2]]] %in% .env$con
    ) |>
    dplyr::select(dplyr::all_of(cols)) |>
    dplyr::collect() |>
    unlist() |>
    unname() |>
    unique()
}

extendedConcepts <- c(
  extractConcepts(concepts, cdm$concept_relationship, toFilter$concept_relationship),
  extractConcepts(concepts, cdm$concept_ancestor, toFilter$concept_ancestor),
  extractConcepts(concepts, cdm$drug_strength, toFilter$drug_strength)
) |>
    unique()

for (tab in names(toFilter)) {
  cols <- toFilter[[tab]]
  for (col in cols) {
    cdm[[tab]] <- cdm[[tab]] |>
      dplyr::filter(.data[[col]] %in% .env$extendedConcepts)
  }
}

names(cdm) |>
  rlang::set_names() |>
  purrr::map_int(\(x) cdm[[x]] |> dplyr::tally() |> dplyr::pull())

# create db
newDb <- DBI::dbConnect(duckdb::duckdb(), here::here("darwinTutorialTest.duckdb"))
DBI::dbExecute(newDb, "CREATE SCHEMA public")
DBI::dbExecute(newDb, "CREATE SCHEMA results")
purrr::map(names(cdm), \(x) {
  tab <- cdm[[x]] |> dplyr::collect()
  if (x == "drug_exposure") {
    tab <- tab |>
      dplyr::mutate(quantity = sample(c(0, 1, 5, 10, 30, 100), size = dplyr::n(), replace = TRUE))
  }
  DBI::dbWriteTable(
    conn = newDb,
    name = DBI::Id(schema = "public", table = x),
    value = tab,
    overwrite = TRUE
  )
}) |>
  invisible()
DBI::dbDisconnect(newDb, shutdown = TRUE)
