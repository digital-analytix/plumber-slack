## ---- api-setup
# Packages ----
library(plumber)
library(magrittr)
library(ggplot2)

# Data ----
# Load sample customer data. IRL this would likely be housed in a database.
sim_data <- readr::read_rds("data/sim-data.rds")

# Config options ----
# Base URL for API requests
base_url <- config::get("base_url")

# Utils ----
encrypt_string <- function(string) {
  urltools::url_encode(safer::encrypt_string(paste(Sys.time(), string, sep = ";"),
                                             key = Sys.getenv("SLACK_SIGNING_SECRET")))
}

plot_auth <- function(endpoint, time_limit = 15) {
  # Save current time to compare against endpoint time value
  current_time <- Sys.time()
  
  # Try to decrypt endpoint and extract user id
  tryCatch({
    # Decrypt endpoint using SLACK_SIGNING_SECRET
    decrypted_endpoint <- safer::decrypt_string(endpoint,
                                                key = Sys.getenv("SLACK_SIGNING_SECRET"))
    # Split endpoint on ;
    endpoint_split <- unlist(strsplit(decrypted_endpoint, split = ";"))
    # Convert time
    endpoint_time <- as.POSIXct(endpoint_split[1])
    # Calculate time difference
    time_diff <- difftime(current_time, endpoint_time, units = "secs")
    
    # If more than 5 seconds have passed since the request was generated, then
    # error
    if (time_diff > time_limit) {
      "Unauthorized"
    } else {
      endpoint_split[2]
    }
  },
  error = function(e) "Unauthorized"
  )
}

#* @apiTitle CS Slack Application API
#* @apiDescription API that interfaces with Slack slash command /cs

## ---- comments
# Requests sent from Slack slash commands are sent as url encoded text in the
# postBody of the request. The text of the command is contained in the text
# field. Full details of what is sent from Slack can be found at
# https://api.slack.com/slash-commands

# req$postBody is either decoded as JSON if it appears to be JSON or it is
# decoded as a standard query string. Fields provided in the post body in
# either format will be matched to function parameters.
# see https://www.rplumber.io/docs/routing-and-input.html#request-body

# Slack uses the notion of signed secrets in order to verify that the request
# was actually made from Slack. This API checks the signed secret against
# a self computed signed secret to ensure they match. If not, an error is
# returned. Detailed instructions for verifying requests can be found
# at https://api.slack.com/docs/verifying-requests-from-slack
# TODO: Is it possible to reject requests from bad actors based on a history
# of incorrectly signed requests? Or is just rejecting the incorrectly signed
# request enough?
# Authentication happens at the endpoint level so that each endpoint MAY have
# it's own method of authentication.

# This filter is responsible for parsing text, routing to the appropriate
# endpoint, and providing arguments to be consumed by that endpoint

## ---- filter-route-endpoint
#* Parse the incoming request and route it to the appropriate endpoint
#* @filter route-endpoint
function(req, text = "") {
  # Identify endpoint
  split_text <- urltools::url_decode(text) %>%
    strsplit(" ") %>%
    unlist()
  
  if (length(split_text) >= 1) {
    endpoint <- split_text[[1]]
    
    # Modify request with updated endpoint
    req$PATH_INFO <- paste0("/", endpoint)
    
    # Modify request with remaining commands from text
    req$ARGS <- split_text[-1] %>% 
      paste0(collapse = " ")
  }
  
  if (req$PATH_INFO == "/") {
    # If no endpoint is provided (PATH_INFO is just "/") then forward to /help
    req$PATH_INFO <- "/help"
  }
  
  # Forward request 
  forward()
}

## ---- filter-logger
#* Log information about the incoming request
#* @filter logger
function(req){
  cat(as.character(Sys.time()), "-", 
      req$REQUEST_METHOD, req$PATH_INFO, "-", 
      req$HTTP_USER_AGENT, "@", req$REMOTE_ADDR, "\n")
  
  # Forward request
  forward()
}

## ---- filter-verify
#* Verify incoming requests
#* @filter verify
function(req, res) {
  # Forward requests coming to swagger endpoints
  if (grepl("swagger", tolower(req$PATH_INFO))) return(forward())
 
  # Check for X_SLACK_REQUEST_TIMESTAMP header
  if (is.null(req$HTTP_X_SLACK_REQUEST_TIMESTAMP)) {
    res$status <- 401
  }
  
  # Build base string
  base_string <- paste(
    "v0",
    req$HTTP_X_SLACK_REQUEST_TIMESTAMP,
    req$postBody,
    sep = ":"
  )
  
  # Slack Signing secret is available as environment variable
  # SLACK_SIGNING_SECRET
  computed_request_signature <- paste0(
    "v0=",
    openssl::sha256(base_string, Sys.getenv("SLACK_SIGNING_SECRET"))
  )
  
  # If the computed request signature doesn't match the signature provided in the
  # request, set status of response to 401
  if (!identical(req$HTTP_X_SLACK_SIGNATURE, computed_request_signature)) {
    res$status <- 401
  } else {
    res$status <- 200
  }
  
  if (res$status == 401) {
    list(
      text = "Error: Invalid request"
    )
  } else {
    forward()
  }
}

## ---- post-help
#* Help for /cs command
#* @serializer unboxedJSON
#* @post /help
function(req, res) {
  list(
    # response type - ephemeral indicates the response will only be seen by the
    # user who invoked the slash command as opposed to the entire channel
    response_type = "ephemeral",
    # attachments is expected to be an array, hence the list within a list
    attachments = list(
      list(
        title = "/cs help",
        fallback = "/cs help",
        fields = list(
          list(
            title = "/cs status customer_id",
            value = "Customer summary",
            short = TRUE
          ),
          list(
            title = "/cs rep rep_name",
            value = "CS rep summary",
            short = TRUE
          ),
          list(
            title = "/cs region region_name",
            value = "Region report",
            short = TRUE
          )
        )
      )
    )
  )
}

## ---- post-status
# unboxedJSON is used b/c that is what Slack expects from the API
#* Return a message containing status details about the customer
#* @serializer unboxedJSON
#* @post /status
function(req, res) {
  # Check req$ARGS and match to customer - if no customer match is found, return
  # an error
  
  # TODO: Provide suggestions for names that are close in the event of mispellings
  
  customer_ids <- unique(sim_data$id)
  customer_names <- unique(sim_data$name)
  
  if (!as.numeric(req$ARGS) %in% customer_ids & !req$ARGS %in% customer_names) {
    res$status <- 400
    return(
      list(
        response_type = "ephemeral",
        text = paste("Error: No customer found matching", req$ARGS)
      )
    )
  }
  
  # Filter data to customer data based on provided id / name
  if (as.numeric(req$ARGS) %in% customer_ids) {
    customer_id <- as.numeric(req$ARGS)
    customer_data <- dplyr::filter(sim_data, id == customer_id)
    customer_name <- unique(customer_data$name)
  } else {
    customer_name <- req$ARGS
    customer_data <- dplyr::filter(sim_data, name == customer_name)
    customer_id <- unique(customer_data$id)
  }
  
  # Simple heuristics for customer status
  total_customer_calls <- sum(customer_data$calls)
  
  customer_status <- dplyr::case_when(total_customer_calls > 250 ~ "danger",
                                      total_customer_calls > 130 ~ "warning",
                                      TRUE ~ "good")
  
  # Build response
  list(
    # response type - ephemeral indicates the response will only be seen by the
    # user who invoked the slash command as opposed to the entire channel
    response_type = "ephemeral",
    # attachments is expected to be an array, hence the list within a list
    attachments = list(
      list(
        color = customer_status,
        title = paste0("Status update for ", customer_name, " (", customer_id, ")"),
        fallback = paste0("Status update for ", customer_name, " (", customer_id, ")"),
        # History plot
        
        image_url = paste0(base_url, 
                           "/plot/history?cust_secret=",
                           encrypt_string(customer_id)),
        # Fields provide a way of communicating semi-tabular data in Slack
        fields = list(
          list(
            title = "Total Calls",
            value = sum(customer_data$calls),
            short = TRUE
          ),
          list(
            title = "DoB",
            value = unique(customer_data$dob),
            short = TRUE
          )
        )
      )
    )
  )
}

## ---- get-plot-history
#* Plot customer weekly calls
#* @png
#* @param cust_secret encrypted value calculated in /status endpoint
#* @response 400 No customer with the given ID was found.
#* @preempt verify
#* @get /plot/history
function(res, cust_secret) {
  # Authenticate that request came from /status
  cust_id <- plot_auth(cust_secret)
  
  # Return unauthorized error if cust_id is "Unauthorized"
  if (cust_id == "Unauthorized") {
    res$status <- 401
    stop("Unauthorized request")
  } else if (!cust_id %in% sim_data$id) {
    res$status <- 400
    stop("Customer id" , cust_id, " not found.")
  }
  
  # Filter data to customer id provided
  plot_data <- dplyr::filter(sim_data, id == cust_id)
  
  # Customer name (id)
  customer_name <- paste0(unique(plot_data$name), " (", unique(plot_data$id), ")")
  
  # Create plot
  history_plot <- plot_data %>%
    ggplot(aes(x = time, y = calls, col = calls)) +
    ggalt::geom_lollipop(show.legend = FALSE) +
    theme_light() +
    labs(
      title = paste("Weekly calls for", customer_name),
      x = "Week",
      y = "Calls"
    )
  
  # print() is necessary to render plot properly
  print(history_plot)
}

## ---- post-rep
#* Get summary of rep performance
#* @serializer unboxedJSON
#* @post /rep
function(req, res) {
  # Check to ensure rep exists in data
  if (!req$ARGS %in% unique(sim_data$rep)) {
    return(
      list(
        response_type = "ephemeral",
        text = paste("Error: No rep found matching", req$ARGS)
      )
    )
  }
  
  rep_data <- dplyr::filter(sim_data, rep == req$ARGS)
  n_clients <- length(unique(rep_data$name))
  
  list(
    # response type - ephemeral indicates the response will only be seen by the
    # user who invoked the slash command as opposed to the entire channel
    response_type = "ephemeral",
    # attachments is expected to be an array, hence the list within a list
    attachments = list(
      list(
        title = paste0("Rep: ", req$ARGS),
        fallback = paste0("Rep: ", req$ARGS),
        fields = list(
          list(
            title = "Total Clients",
            value = n_clients,
            short = TRUE
          ),
          list(
            title = "Calls / Client",
            value = sum(rep_data$calls) / n_clients,
            short = TRUE
          )
        )
      )
    )
  )
}

## ---- post-region
#* Summary of region performance
#* @serializer unboxedJSON
#* @post /region
function(req, res) {
  # Check to ensure provided region value exists in data
  if (!tolower(req$ARGS) %in% tolower(unique(sim_data$region))) {
    return(
      list(
        reponse_type = "ephemeral",
        text = paste("Error: No region found matching", req$ARGS)
      )
    )
  }
  
  region_data <- dplyr::filter(sim_data, tolower(region) == tolower(req$ARGS))
  
  list(
    response_type = "ephemeral",
    attachments = list(
      list(
        title = paste0("Region: ", req$ARGS),
        fallback = paste0("Region: ", req$ARGS),
        image_url = paste0(base_url, "/plot/region?region_name=",
                           encrypt_string(tolower(req$ARGS))),
        fields = list(
          list(
            title = "Total Clients",
            value = length(unique(region_data$name)),
            short = TRUE
          )
        )
      )
    )
  )
}

## ---- get-plot-region
#* Plot region data
#* @png
#* @param region_name Name of region to be plotted
#* @preempt verify
#* @get /plot/region
function(region_name, req, res) {
  region_name <- plot_auth(region_name)
  if (region_name == "Unauthorized") {
    res$status <- 401
    stop("Unauthorized request")
  } else if (!tolower(region_name) %in% tolower(sim_data$region)) {
    res$status <- 400
    stop("Region " , region_name, " not found.")
  }
  
  region_plot <- sim_data %>% 
    dplyr::filter(tolower(region) == tolower(region_name)) %>% 
    ggplot(aes(x = time, y = calls)) +
    geom_jitter(alpha = .3) +
    geom_smooth(se = FALSE) +
    theme_light() +
    labs(
      title = paste("Call trend for", region_name, "Region"),
      x = "Week",
      y = "Calls"
    )
  
  print(region_plot)
}
