#' calculate summary statistics for each subsampled depth in a subsamples object
#' 
#' Given a subsamples object, calculate a metric for each depth that summarizes
#' the power, the specificity, and the accuracy of the effect size estimates at
#' that depth.
#' 
#' To perform these calculations, one must compare each depth to an "oracle" depth,
#' which, if not given explicitly, is assumed to be the highest subsampling depth.
#' This thus summarizes how closely each agrees with the full experiment: if very
#' low-depth subsamples still agree, it means that the depth is high enough that
#' the depth does not make a strong qualitative difference.
#' 
#' @param object a subsamples object
#' @param oracle a subsamples object of one depth showing what each depth should 
#' be compared to; if NULL, each will be compared to the highest depth
#' @param FDR.level A false discovery rate used to calculate the number of genes
#' found significant at each level
#' @param average If TRUE, averages over replications at each method+depth
#' combination before returning
#' @param p.adjust.method Method to correct p-values in order to determine significance.
#' By default "qvalue", but can also be given any method that can be given to p.adjust.
#' @param ... further arguments passed to or from other methods.
#' 
#' @return A summary object, which is a \code{data.table}
#' with one row for each subsampling depth, containing the metrics
#' 
#' \item{significant}{number of genes found significant at the given FDR}
#' \item{pearson}{Pearson correlation of the coefficient estimates with the oracle}
#' \item{spearman}{Spearman correlation of the coefficient estimates with the oracle}
#' \item{concordance}{Concordance correlation of the coefficient estimates with the oracle}
#' \item{MSE}{mean squared error between the coefficient estimates and the oracle}
#' \item{estFDP}{estimated FDP: the estimated false discovery proportion, as calculated from the
#' average oracle local FDR within genes found significant at this depth}
#' \item{rFDP}{relative FDP: the proportion of genes found significant at this depth that were not found
#' significant in the oracle}
#' \item{percent}{the percentage of genes found significant in the oracle that
#' were found significant at this depth}
#' 
#' @details The concordance correlation coefficient is described in Lin 1989.
#' Its advantage over the Pearson is that it takes into account not only
#' whether the coefficients compared to the oracle close to a straight line,
#' but whether that line is close to the x = y line.
#' 
#' Note that selecting average=TRUE averages the depths of the replicates
#' (as two subsamplings with identical proportions may have different depths by
#' chance). This may lead to depths that are not integers.
#' 
#' @references
#' 
#' Lawrence I-Kuei Lin (March 1989). "A concordance correlation coefficient to evaluate reproducibility".
#' Biometrics (International Biometric Society) 45 (1): 255-268.
#' 
#' @examples
#' # see subsample function to see how ss is generated
#' data(ss)
#' # summarise subsample object
#' ss.summary = summary(ss)
#' 
#' @importFrom qvalue lfdr
#' @importFrom dplyr group_by summarize mutate filter select inner_join
#' @import magrittr
#' @importFrom tidyr gather spread
#' 
#' @export
summary.subsamples <-
function(object, oracle=NULL, FDR.level=.05, average=FALSE, 
         p.adjust.method="qvalue", ...) {
    # find the oracle for each method
    tab = as.data.frame(object)
    tab = tab %>% filter(count != 0)
    tab = tab %>% mutate(method=as.character(method))

    if (is.null(oracle)) {
        # use the highest depth in each method
        oracles = tab %>% group_by(method) %>% filter(depth == max(depth))
    }
    else {
        # oracle is the same for all methods
        oracles = data.frame(method=unique(object$method)) %>%
            group_by(method) %>% do(oracle)
    }

    # calculate lfdr for each oracle
    lfdr1 = function(p) {
        # calculate for all p-values that aren't equal to 1 separately
        non1.lfdr = lfdr(p[p != 1])
        ret = rep(max(non1.lfdr), length(p))
        ret[p != 1] = non1.lfdr
        ret
    }
    oracles = oracles %>% group_by(method) %>% mutate(lfdr=lfdr1(pvalue))

    # compute adjusted p-values in oracles and data
    if (p.adjust.method == "qvalue") {
        # q-values were already calculated by the subsample function
        tab$padj = tab$qvalue
        oracles$padj = oracles$qvalue
    } else {
        tab = tab %>% group_by(method, proportion, replication) %>% mutate(padj=p.adjust(pvalue, method=p.adjust.method)) %>% group_by()
        oracles = oracles %>% group_by(method, proportion, replication) %>% mutate(padj=p.adjust(pvalue, method=p.adjust.method)) %>% group_by()
    }

    # combine with oracle
    sub.oracle = oracles %>% select(method, ID, o.padj=padj,
                                     o.coefficient=coefficient, o.lfdr=lfdr)
    tab = tab %>% inner_join(sub.oracle, by=c("method", "ID"))
    
    # summary operation
    ret = tab %>% group_by(depth, proportion, method, replication) %>%
        mutate(valid=(!is.na(coefficient) & !is.na(o.coefficient))) %>%
        summarize(significant=sum(padj < FDR.level),
                  pearson=cor(coefficient, o.coefficient, use="complete.obs"),
                  spearman=cor(coefficient, o.coefficient, use="complete.obs", method="spearman"),
                  concordance = ccc(coefficient, o.coefficient),
                  MSE=mean((coefficient[valid] - o.coefficient[valid])^2),
                  estFDP=mean(o.lfdr[padj < FDR.level]),
                  rFDP=mean((o.padj > FDR.level)[padj < FDR.level]),
                  percent=mean(padj[o.padj < FDR.level] < FDR.level))

    # any case where none are significant, the estFDP/rFDP should be 0 (not NaN)
    # since technically there were no false discoveries
    ret = ret %>% mutate(estFDP=ifelse(significant == 0, 0, estFDP)) %>%
        mutate(rFDP=ifelse(significant == 0, 0, rFDP))

    if (average) {
        # average each metric within replications
        ret = ret %>% gather(metric, value, significant:percent) %>%
            group_by(proportion, method, metric) %>%
            summarize(value=mean(value)) %>% group_by() %>% spread(metric, value)
    }
    
    ret = as.data.table(as.data.frame(ret))
    class(ret) = c("summary.subsamples", "data.table", "data.frame")
    attr(ret, "seed") = attr(object, "seed")
    attr(ret, "FDR.level") = FDR.level
    ret
}

ccc <- function(x, y){
    complete <- !is.na(x) & !is.na(y)
    (2 * cov(x, y)) / (var(x) + var(y) + (mean(x) - mean(y))^2)
}
