# produce random directions, and choose the 'out' best directions
# best directions are those that minimise entropy
# zeros=TRUE allow some elements of the direction to be zero
# with a higher change of those associated with lower PC loadings being zero
.rand.dirs <- function(z, IC, k, m, iter=5000, out, seed, zeros=TRUE) {
    p <- ncol(z)
    n <- nrow(z)
    if(missing(m)) m <- floor(sqrt(n))
    if(missing(k)) k <- 1
    if(missing(IC)) IC <- diag(p)
    r <- p - k + 1 # the dimension of the search space

    if (!missing(seed)) set.seed(seed)
    trials_mat <- matrix(rnorm(r*iter), iter, r)
    # lets try with some elements zero
    # seemed to work well when tried a while back
    if(zeros == TRUE) {
        # probs means that the smaller PC loadings are more
        # likely to be ignored.
        probs <- seq(from=1/r, to=1, length=r)
        trials_mat <- t(apply(trials_mat, 1, function(trials) {
            # always want at least two non-zero elements
            # otherwise would just get the PC loading back
            sampp <- sample(1:r, size=sample(1:(r-2), 1), 
                                replace=FALSE, prob=probs)
            trials[sampp] <- 0
            trials
            }))
    }
    trials_mat <- trials_mat / sqrt(rowSums(trials_mat^2))
    trials.orig.space <- trials_mat %*% t(IC[,k:p])
    # switch to columns for each trial so that entr works
    trials.proj <- trials.orig.space %*% t(z)
    entr <- entropy(trials.proj, m=m)

    dir.table <- cbind(entr, trials_mat)
    # arange in order
    dir.table <- dir.table[order(dir.table[,1]),]
    namesW <- paste0('dir', seq_len(iter))
    if(!missing(out)) {
        if(out > iter) {
            warning("out > iter: have set out = iter")
            out <- iter
        }
        dir.table <- dir.table[1:(out),]
        namesW <- paste0('dir', seq_len(out))
    }
    
    entr <- dir.table[,1]
    dirs <- dir.table[,-1]

    rownames(dirs) <- namesW
    colnames(dirs) <- NULL
    output <- list()
    output$entr <- entr
    output$dirs <- dirs
    output
}



# put random directions into clusters
# uses divisive kmeans clustering from cluster.proj.divisive
.cluster.norm <- function(z, IC, k, m, dirs, kmeans_tol=0.1,
                         kmeans_iter=100, save.all=FALSE, clust_avg=FALSE) {
    # convert dirs to listrbose=
    p <- ncol(z)
    n <- nrow(z)
    if(missing(m)) m <- floor(sqrt(n))
    if(missing(IC)) IC <- diag(p)
    if(missing(k)) k <- 1

    #stopifnot(p == ncol(dirs))
    entr <- dirs$entr
    dirs <- dirs$dirs
    dirs.list <- lapply(seq_len(nrow(dirs)), function(i) dirs[i,])

    # list of clusters

    # K-Means Cluster Analysis: Divisive
    c <- cluster.proj.divisive(X=dirs, tol=kmeans_tol, iter.max=kmeans_iter)
    clusters <- max(c$c)
    
    # append cluster assignment & put into list
    out_tmp <- vector(mode = "list", length = clusters)
    dirs.cluster_append <- cbind(c$c, entr, dirs)
    for(i in 1:clusters) {
        which.cluster <- which(dirs.cluster_append[,1] == i)
        if (save.all == FALSE & clust_avg==FALSE) {
            out_tmp[[i]]$entr <- dirs.cluster_append[which.cluster, 2]
            entr_min <- which.min(out_tmp[[i]]$entr)
            out_tmp[[i]]$entr <- out_tmp[[i]]$entr[entr_min]
            out_tmp[[i]]$dirs <- dirs.cluster_append[which.cluster, c(-1, -2), 
                                                        drop=FALSE]
            out_tmp[[i]]$dirs <- out_tmp[[i]]$dirs[entr_min,]
        } else {
            out_tmp[[i]]$entr <- dirs.cluster_append[which.cluster, 2]
            out_tmp[[i]]$dirs <- dirs.cluster_append[which.cluster, c(-1, -2)]
            if (clust_avg == TRUE) {
                s <- La.svd(out_tmp[[i]]$dirs, nu=0, nv=1)
                centre <- s$vt[1,]
                out_tmp[[i]]$dirs <- centre
                # calc entropy of centre
                centre.orig.space <- centre %*% t(IC[,k:p])
                centre.proj <- centre.orig.space %*% t(z)
                entr <- entropy(centre.proj, m=m)
                out_tmp[[i]]$entr <- entr
            }
        }
    }
    out_tmp
    return(out_tmp)
}

# optimise each direction
# here dir is a single direction (vector)
# cluster arg only used for cat() in clusterICA
.dir.optim <- function(z, IC, k, m, dirs, maxit=1000, 
                        cluster, opt_method="Nelder-Mead") {
    n <- ncol(z)

    opt <- optim(par = dirs,
                 function(w) {
                     w <- w / sqrt(sum(w^2))
                     w.orig.space <- IC %*% c(rep(0, k-1), w)
                     z_proj <- t(z %*% w.orig.space)
                     entropy(z_proj, m = m)
                 }, method = opt_method, control = list(maxit = maxit))
    
    if (opt$convergence == 1) {
        warning("In cluster ", cluster, " optimisation did not converge, consider increasing maxit")
    } else if (opt$convergence != 0) {
        warning("In cluster ", cluster, " optimisation did not converge (error ", opt$convergence, ")")
    }
    
    entr_tmp <- opt$value
    dir_tmp <- opt$par
    dir_tmp <- dir_tmp / sqrt(sum(dir_tmp^2))
    
    output <- list()
    output$entr <- entr_tmp
    output$dirs <- dir_tmp
    output
}

# create a single ICA loading from clustered random projections
# input is from .cluster.norm
.ica.clusters <- function(z, IC, k, m, best_dirs, maxit=1000,
                         opt_method="Nelder-Mead", size_clust,
                         clust_avg=FALSE) {
    n <- nrow(z)
    p <- ncol(z)
    if(missing(m)) m <- floor(sqrt(n))
    if(missing(IC)) IC <- diag(p)
    if(missing(k)) k <- 1

    clusters <- length(best_dirs)
    cat("////Optimising direction of projection on ", clusters, " clusters \n")

    dir_opt <- matrix(nrow = clusters, ncol = (p  - k + 1 + 1))
    dir_opt_many <- vector(mode="list", length=clusters)
    nn <- numeric()
    for(i in 1:clusters) {
        cat("//// Optimising cluster ", i, "\n")
        dir_tmp <- best_dirs[[i]]
        n_tmp <- length(dir_tmp$entr)
        nn[i] <- n_tmp
        if(n_tmp == 1) {
            dir_opt_tmp <- .dir.optim(z = z, IC = IC, dirs = dir_tmp$dirs,
                                     k = k, m = m, maxit = maxit,
                                     cluster=i, opt_method=opt_method)

        } else {
            # randomly choose size_clust dirs to optimise in each cluser
            if(is.numeric(size_clust)) {
                samp <- sample(n_tmp, size = min(size_clust, n_tmp))
            } else {
                samp <- seq_len(n_tmp)
            }
            dir_opt_clust <- lapply(samp, function(j) {
                dirr <- dir_tmp$dirs[j,]
                dir_opt_tmp <- .dir.optim(z = z, IC = IC, dirs = dirr,
                                         k = k, m = m, maxit = maxit, cluster=i,
                                         opt_method=opt_method)
            })
            dir_entr_tmp <- sapply(dir_opt_clust, function(x) x$entr)
            dir_dir_tmp <- t(sapply(dir_opt_clust, function(x) x$dir))
            names_tmp <- names(dir_tmp$entr)
            dir_table <- cbind(dir_entr_tmp, dir_dir_tmp)
            ord_tmp <- order(dir_table[,1])
            dir_table <- dir_table[ord_tmp,]
            names_tmp <- names_tmp[ord_tmp]
            dir_entr_tmp <- dir_table[,1]
            names(dir_entr_tmp) <- names_tmp
            dir_dir_tmp <- dir_table[,-1]
            min_entr <- which.min(dir_entr_tmp)

            dir_opt_tmp <- list(entr=dir_entr_tmp[min_entr], 
                                    dirs=dir_dir_tmp[min_entr,])
            dir_opt_many[[i]] <- list(entr=dir_entr_tmp, dirs=dir_dir_tmp)
        }

        dir_opt[i,] <- c(dir_opt_tmp$entr, dir_opt_tmp$dirs)
    }
    cluster_num <- which.min(dir_opt[,1])
    output <- list()
    output$cluster_num <- cluster_num
    output$dir_entr <- dir_opt[cluster_num, 1]
    output$dir_optim <- dir_opt[cluster_num, -1]
    if (any(nn > 1)) {
        return(list(best=output, all=dir_opt_many))
    } else {
        return(output)
    }
}

# for class clusterICA
print.clusterICA <- function(x, ...) {
    loadings <- ncol(x$IC)
    length <- nrow(x$IC)
    entr1 <- round(x$entr[1], digits = 5)
    cat("Cluster ICA: ", loadings, " loading(s) found of length ", length,
        ". Best projection has entropy ", entr1, ".\n", sep="")
    invisible(x)
}
