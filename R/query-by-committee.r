#' Active learning with "Query by Committee"
#'
#' The 'query by committee' approach to active learning uitilizes a committee of
#' \code{C} classifiers that are each trained on the labeled training data. Our
#' goal is to "query the oracle" with the observations that have the maximum
#' disagreement among the \code{C} trained classifiers.
#'
#' Note that this approach is similar to "Query by Bagging" (QBB), but each
#' committee member is specified by the user. With the QBB approach, only one
#' supervised classifier is specified by the user, and each committee member is
#' trained on a resampled subset of  the labeled training data. Also, note that
#' we have implemented QBB as \code{\link{query_by_bagging}}.
#'
#' To determine maximum disagreement among committee committe members, we have
#' implemented three approaches:
#'
#' \describe{
#' \item{vote_entropy}{query the unlabeled observation that maximizes the vote
#' entropy among all commitee members}
#' \item{post_entropy}{query the unlabeled observation that maximizes the entropy
#' of average posterior probabilities of all committee members}
#' \item{kullback}{query the unlabeled observation that maximizes the
#' Kullback-Leibler divergence between the label distributions of any one
#' committe member and the consensus}.
#'
#' The \code{disagreement} argument must be one of the three: \code{kullback} is
#' the default.
#'
#' To calculate the committee disagreement, we use the formulae from Dr. Burr
#' Settles' "Active Learning Literature Survey" available on his website.
#' At the time this function was coded, the literature survey had last been
#' updated on January 26, 2010.
#'
#' In specifying the committee members, we require a list (called 'committee'
#' in the arguments) with elements corresponding to each supervised classifier
#' (each committee member). Each component in the list 'committee' should be a
#' list with the following named elements:
#' \describe{
#' \item{train}{a string that specifies the function name of the supervised
#' classifier}
#' \item{train_args}{(optional) a list that specifies additional arguments to
#' pass to the \code{train} function}
#' \item{predict}{a string that specifies the classifier's corresponding
#' prediction (classification) function}
#'
#' In the examples below, we provide an example here that uses the linear
#' discriminant analysis (LDA) implementation in the \code{\link{MASS}} package
#' as well as the regularized discriminant analysis (RDA) implementation in the
#' \code{klaR} package. Each training function arguments \code{x} for the data
#' matrix and \code{grouping} as the vector of class labels. Furthermore, the RDA
#' classifier accepts two optional tuning parameters, \code{lambda} and
#' \code{gamma}. If the models are not provided they are estimated automatically.
#' In our example, we consider using both the RDA model with and without
#' user-specified tuning parameters. Note that both the LDA and RDA classifiers
#' use \code{predict} as their classification functions. The specified
#' \code{committee} can be formulated by:
#'
#' Unlabeled observations in \code{y} are assumed to have \code{NA} for a label.
#'
#' It is often convenient to query unlabeled observations in batch. By default,
#' we query the unlabeled observation with the largest disagreement measure
#' value. With the \code{num_query} the user can specify the number of
#' observations to return in batch. If there are ties in the disagreement measure
#' values, they are broken by the order in which the unlabeled observations are
#' given.
#'
#' This method uses the \code{\link{foreach}} package and is set to do the train
#' each committee member in parallel if a parallel backend is registered. If
#' there is no parallel backend registered, a warning is thrown, but everything
#' will work just fine.
#'
#' @param x a matrix containing the labeled and unlabeled data
#' @param y a vector of the labels for each observation in \code{x}. Use
#' \code{NA} for unlabeled.
#' @param committee a list containing the committee of classifiers. See details
#' for the required format.
#' @param disagreement a string that contains the disagreement measure among the
#' committee members. See above for details.
#' @param num_query the number of observations to be queried.
#' @return a list that contains the least_certain observation and miscellaneous
#' results. See above for details.
#' @examples
#' lda_wrapper <- function(x, y, ...) { lda(x = x, grouping = y, ...) }
#' rda_wrapper <- function(x, y, ...) { rda(x = x, grouping = y, ...) }
#' rda_args <- list(lambda = 1, gamma = 0.1)
#'
#' committee <- list(
#'    LDA = list(train = lda_wrapper, predict = predict),
#'    RDA = list(train = rda_wrapper, train_args = rda_args, predict = predict),
#'    RDA_auto = list(train = rda_wrapper, predict = predict)
#' )
query_by_committee <- function(x, y, committee,
                               disagreement = c("kullback", "vote_entropy",
                                 "post_entropy"), num_query = 1, num_cores = 1,
                               ...) {
  warning("The 'query_by_committee' function is experimental.")
  # Validates the classifier string.
  validate_classifier(classifier, posterior_prob = TRUE)

	unlabeled <- which_unlabeled(y)
	n <- length(y) - length(unlabeled)
  
  train_x <- x[-unlabeled, ]
  train_y <- y[-unlabeled]
  test_x <- x[unlabeled, ]

	# Committee predictions
	committee_pred <- mclapply(committee, function(c_member) {
	  predict <- get(c_member$predict)
	  args_string <- with(c_member, paste(names(train_args), train_args$train_args,
                                        sep = "=", collapse = ", "))
	  args_string <- paste0('x = train_x, y = train_y, ', args_string)
    function_call <- paste0(c_member$train, "(", args_string, ")")
    train_out <- eval(parse(text = function_call))
		predict(train_out, test_x)
	})
	
	committee_post <- lapply(committee_pred, function(x) {
    x$posterior
  })
	committee_class <- do.call(rbind, lapply(committee_pred, function(x) x$class))

	disagree <- switch(uncertainty,
                     vote_entropy = apply(committee_class, 2, function(x) {
                       entropy.empirical(table(factor(x, levels = classes)))
                     }),
                     post_entropy = {
                       committee_post <- lapply(committee_pred, function(x) {
                         x$posterior
                        })
                       avg_post <- Reduce('+', committee_post)
                       avg_post <- avg_post / length(committee_post)
                       apply(avg_post, 1, function(obs_post) {
                         entropy.plugin(obs_post)
                       })
                     },
                     kullback = {
                       committee_post <- lapply(committee_pred, function(x) {
                         x$posterior
                       })
                       consensus_prob <- Reduce('+', committee_post)
                       consensus_prob <- consensus_prob / length(committee_post)
                       kl_post_by_member <- lapply(committee_post, function(x) {
                         rowSums(x * log(x / consensus_prob))
                       })
                       Reduce('+', kl_post_by_member) / length(kl_post_by_member)
                     }
                    )

  query <- order(obs_disagreement, decreasing = TRUE)[seq_len(num_query)]
	
	list(query = query, obs_disagreement = obs_disagreement,
       committee_class = committee_class, committee_post = committee_post,
       unlabeled = unlabeled)
}