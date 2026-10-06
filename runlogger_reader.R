# runlogger_reader.R -- helpers for reading Run Logger save files (RLOG2 format)
suppressPackageStartupMessages({ library(jsonlite); library(dplyr) })

`%||%` <- function(a, b) if (is.null(a)) b else a

# ---- 1. Read one save file ---------------------------------------------------
read_runlogger <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  stopifnot("not an RLOG2 file" = startsWith(lines[1], "RLOG2 "))
  sep <- which(lines == "--LOG--")[1]
  stopifnot("missing --LOG-- separator" = !is.na(sep))
  header      <- fromJSON(sub("^RLOG2 ", "", lines[1]), simplifyVector = FALSE)
  stats_lines <- if (sep > 2) lines[2:(sep - 1)] else character()
  run_lines   <- if (sep < length(lines)) lines[(sep + 1):length(lines)] else character()
  run_lines   <- run_lines[nzchar(run_lines)]
  runs        <- lapply(run_lines, fromJSON)   # arrays of objects become data frames
  list(header = header, stats_lines = stats_lines, runs = runs, path = path)
}

# ---- 2. One row per run ------------------------------------------------------
runs_table <- function(x) {
  bind_rows(lapply(seq_along(x$runs), function(i) { r <- x$runs[[i]]; tibble::tibble(
    file = basename(x$path),
    run_idx = i,                                 # position in the file, oldest first
    run_id = as.character(r$run_id),
    timestamp = r$timestamp %||% NA_character_,
    slot = as.numeric(r$slot %||% NA),
    character = as.numeric(r$character %||% NA),
    difficulty = as.numeric(r$difficulty %||% NA),
    challenge = as.numeric(r$challenge %||% 0),
    won = r$won %||% NA,                       # TRUE / FALSE / NA (abandoned)
    abandoned = isTRUE(r$abandoned),
    continuable_save = r$continuable_save %||% NA,
    continued = isTRUE(r$continued),
    floor_reached = as.numeric(r$floor_reached %||% NA),
    stage_type_reached = as.numeric(r$stage_type_reached %||% NA),
    hits_taken = as.numeric(r$hits_taken %||% NA),
    start_frame = as.numeric(r$start_time %||% NA),
    end_frame = as.numeric(r$end_time %||% NA),
    seed = r$seed %||% NA_character_,
    logger_version = r$logger_version %||% NA_character_
  ) }))
}

# ---- 3. One row per nested record (items, item_spawns, damage_events, ...) ----
unnest_field <- function(x, field) {
  bind_rows(lapply(seq_along(x$runs), function(i) {
    r <- x$runs[[i]]
    d <- r[[field]]
    if (!is.data.frame(d) || nrow(d) == 0) return(NULL)
    d$file <- basename(x$path)
    d$run_idx <- i                               # join back to runs_table() on file + run_idx
    d$run_id <- as.character(r$run_id)
    d$timestamp <- r$timestamp %||% NA_character_
    d
  }))
}

# ---- 4. Damage: real hits and attribution (mirrors the mod) -------------------
# A raw event starts a new "real hit" only if amount > 0 and it lands after the
# previous counted hit's invulnerability window (time + iframes) has expired.
# The game flags damage the player chose to take (curse and Mausoleum doors, beggars)
# as "no penalties". The mod leaves it out of every hits figure, and records the flag
# bit on each new run as toll_flag_mask. run_toll_mask(x) reads it back; pass NA to
# count everything (that is what the stored hits_taken does). The mask is a single bit,
# so a floor division tests it without 64-bit bitwise operators.
run_toll_mask <- function(x) {
  m <- unlist(lapply(x$runs, function(r) r$toll_flag_mask))
  if (length(m) == 0) NA_real_ else as.numeric(m[1])
}
is_toll <- function(flags, mask) !is.na(mask) & !is.na(flags) & ((flags %/% mask) %% 2 == 1)

# Sources that are always a toll, flag or not ("<source type>_<source variant>").
# Keep in sync with TOLL_SOURCES in main.lua. This also catches events logged before
# damage flags existed.
TOLL_SOURCES <- c("6_5",      # devil beggar
                  "6_2",      # blood donation machine
                  "0_10003")  # the door to the Mausoleum

flag_real_hits <- function(events, toll_mask = NA_real_, toll_sources = character()) {
  events <- events[order(events$time), ]
  if (!"damage_flags" %in% names(events)) events$damage_flags <- NA_real_
  toll <- is_toll(events$damage_flags, toll_mask) |
    (paste(events$source_type, events$source_variant, sep = "_") %in% toll_sources)
  events$toll <- toll
  until <- -Inf
  flag <- logical(nrow(events))
  for (k in seq_len(nrow(events))) {
    amt <- events$amount[k]; if (is.na(amt)) amt <- 0
    if (amt > 0 && events$time[k] >= until && !toll[k]) {
      flag[k] <- TRUE
      fr <- events$iframes[k]; if (is.na(fr)) fr <- 0
      until <- events$time[k] + fr
    }
  }
  events$real_hit <- flag
  events
}

attribute_damage <- function(ev) {
  if (!"spawner_type"  %in% names(ev)) ev$spawner_type  <- NA_real_   # older logs
  if (!"spawner_variant" %in% names(ev)) ev$spawner_variant <- NA_real_
  if (!"damage_flags"  %in% names(ev)) ev$damage_flags  <- NA_real_
  ev %>% mutate(
    kind = case_when(
      source_type == 0 & source_variant == 0 & !is.na(damage_flags)       ~ "environment",
      source_type %in% c(9, 1000) & is.na(spawner_type)                   ~ "legacy",
      source_type %in% c(9, 1000) & spawner_type > 0 & spawner_type != 1  ~ "spawner",
      TRUE                                                                ~ "direct"),
    attr_type    = if_else(kind == "spawner", spawner_type,    source_type),
    attr_variant = if_else(kind == "spawner", spawner_variant, source_variant))
}

# ---- 4b. Hits per minute after pickup (mirrors the mod's stats) -----------------
# For each item, in each run: real hits and game frames from its FIRST pickup to the
# end of the run. Rate = sum(hits_after) / (sum(frames_after) / 3600). Runs of every
# mode count, completed or abandoned. Items found late are measured in later (harder)
# rooms, so compare with the overall rate (see run_hit_rate) and adjust for floor in
# any real model.
item_exposure <- function(x, toll_mask = run_toll_mask(x)) {
  bind_rows(lapply(seq_along(x$runs), function(i) {
    r <- x$runs[[i]]
    items <- r$items
    if (!is.data.frame(items) || nrow(items) == 0 || is.null(r$end_time)) return(NULL)
    ev <- r$damage_events
    hit_times <- if (is.data.frame(ev) && nrow(ev) > 0) {
      flag_real_hits(ev, toll_mask, TOLL_SOURCES) %>% filter(real_hit) %>% pull(time)
    } else numeric()
    first <- items %>% filter(!is.na(time)) %>% group_by(id) %>%
      summarise(t0 = min(time), .groups = "drop") %>% filter(t0 <= r$end_time)
    if (nrow(first) == 0) return(NULL)
    first %>% mutate(file = basename(x$path), run_idx = i,
                     hits_after   = vapply(t0, function(t) sum(hit_times >= t), numeric(1)),
                     frames_after = r$end_time - t0)
  }))
}

# Same measure for transformations: from the frame each form was gained to run end.
form_exposure <- function(x, toll_mask = run_toll_mask(x)) {
  bind_rows(lapply(seq_along(x$runs), function(i) {
    r <- x$runs[[i]]
    tf <- r$transformations
    if (!is.data.frame(tf) || nrow(tf) == 0 || is.null(r$end_time)) return(NULL)
    ev <- r$damage_events
    hit_times <- if (is.data.frame(ev) && nrow(ev) > 0) {
      flag_real_hits(ev, toll_mask, TOLL_SOURCES) %>% filter(real_hit) %>% pull(time)
    } else numeric()
    tf <- tf[!duplicated(tf$name), ]
    tf$file <- basename(x$path); tf$run_idx <- i
    tf$hits_after   <- vapply(tf$time, function(t) sum(hit_times >= t), numeric(1))
    tf$frames_after <- ifelse(tf$time <= r$end_time, r$end_time - tf$time, NA_real_)
    tf
  }))
}

# The exact inventory at the end of each run (new runs only; player 1 collectibles).
# Older runs have no final_items; some have item_snapshots instead (see unnest_field).
final_inventory <- function(x) unnest_field(x, "final_items")

# Whole-run baseline: real hits and frames per run (same definition).
run_hit_rate <- function(x, toll_mask = run_toll_mask(x)) {
  bind_rows(lapply(seq_along(x$runs), function(i) {
    r <- x$runs[[i]]
    if (is.null(r$end_time)) return(NULL)
    ev <- r$damage_events
    n <- if (is.data.frame(ev) && nrow(ev) > 0) sum(flag_real_hits(ev, toll_mask, TOLL_SOURCES)$real_hit) else 0
    tibble::tibble(file = basename(x$path), run_idx = i, hits = n,
                   frames = r$end_time - (r$start_time %||% 0))
  }))
}

# ---- 5. The text stats block (aggregates, includes runs that rolled off the log) -
parse_stats_block <- function(lines) {
  item_fields   <- c("seen","seenBlind","encounteredRunCount","pickedUp","pickedUpBlind",
                     "pickUpFloorSum","pickUpFloorCount","runCount","floorRunCount","floorSum","winCount",
                     "hitsAfter","framesAfter")
  bucket_fields <- c("totalRuns","completedRuns","wins","hitsSum","floorRuns","floorSum",
                     "allHits","allFrames","tollHits")
  form_fields   <- c("gained","completed","wins","gainFloorSum","gainFloorCount","hitsAfter","framesAfter")
  buckets <- list(); items <- list(); sources <- list(); floors <- list(); forms <- list(); cur <- NA_character_
  for (ln in lines) {
    p <- strsplit(ln, " ", fixed = TRUE)[[1]]
    tag <- p[1]
    if (tag == "B") {
      cur <- paste(p[2], p[3], sep = ":")
      buckets[[length(buckets) + 1]] <- c(list(bucket = cur, character = as.numeric(p[2]), mode = p[3]),
                                          setNames(as.list(as.numeric(p[4:(3 + length(bucket_fields))])), bucket_fields))
    } else if (tag == "I") {
      items[[length(items) + 1]] <- c(list(bucket = cur, id = as.numeric(p[2])),
                                      setNames(as.list(as.numeric(p[3:(2 + length(item_fields))])), item_fields))
    } else if (tag == "S") {
      sources[[length(sources) + 1]] <- list(bucket = cur, source_type = as.numeric(p[2]),
                                             source_variant = as.numeric(p[3]), hits = as.numeric(p[4]))
    } else if (tag == "F") {
      sp <- strsplit(p[2], "_", fixed = TRUE)[[1]]
      floors[[length(floors) + 1]] <- list(bucket = cur, stage = as.numeric(sp[1]), stage_type = as.numeric(sp[2]),
                                           runs = as.numeric(p[3]), hits = as.numeric(p[4]))
    } else if (tag == "T") {
      forms[[length(forms) + 1]] <- c(list(bucket = cur, name = gsub("_", " ", p[2], fixed = TRUE)),
                                      setNames(as.list(as.numeric(p[3:(2 + length(form_fields))])), form_fields))
    }
  }
  list(buckets = bind_rows(buckets), items = bind_rows(items),
       sources = bind_rows(sources), floors = bind_rows(floors), forms = bind_rows(forms))
}

# ---- 6. Several slot files at once, de-duplicated -----------------------------
read_all_slots <- function(paths) {
  xs <- lapply(paths, read_runlogger)
  runs <- bind_rows(lapply(xs, runs_table))
  runs %>% distinct(run_id, timestamp, .keep_all = TRUE)   # same seed replayed != same run
}
