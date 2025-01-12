detect_communities <- function(graph, 
                               algorithm = "leiden", 
                               resolution = 1,
                               weight = "ncweight",
                               metric = "average",
                               chains) {
    
    check_inputs(graph = graph,
                 algorithm = algorithm, 
                 resolution = resolution,
                 weight = weight, 
                 metric = metric, 
                 chains = chains)
    
    message("[1/5] formatting graph...")
    cg <- get_formatted_graph(graph = graph, 
                              weight = weight, 
                              metric = metric,
                              chains = chains) 
    
    message("[2/5] community detection...")
    cg <- get_community_detection(g = cg, 
                                  algorithm = algorithm, 
                                  resolution = resolution)
    
    message("[3/5] community summary...")
    cs <- get_community_summary(g = cg, chains = chains)
    
    message("[4/5] extracting community occupancy matrix...")
    cm <- get_community_matrix(g = cg)
    
    message("[5/5] extracting nodes")
    vs <- as_data_frame(x = cg, what = "vertices")
    
    # save configs
    config <- list(input_g = graph, 
                   algorithm = algorithm, 
                   resolution = resolution,
                   weight = weight, 
                   metric = metric,
                   chains = chains)
    
    return(list(community_occupancy_matrix = cm, 
                community_summary = cs, 
                node_summary = vs, 
                graph = cg, 
                input_config = config))
}

get_formatted_graph <- function(graph, 
                                weight,
                                metric,
                                chains) {
    
    set_weight <- function(graph, weight) {
        if(weight == "ncweight") {
            E(graph)$weight <- E(graph)$ncweight
        }
        if(weight == "nweight") {
            E(graph)$weight <- E(graph)$nweight
        }
        return(graph)
    }
    
    set_chain <- function(graph, chains) {
        i <- which(!E(graph)$chain %in% chains)
        if(length(i)!=0) {
            graph <- delete_edges(graph = graph, i)
        }
        return(graph)
    }
    
    graph <- set_weight(graph = graph, weight = weight)
    graph <- set_chain(graph = graph, chains = chains)
    
    graph <- simplify(graph, edge.attr.comb = list(weight = "concat",
                                                   chain = "concat",
                                                   "ignore"))
    
    if(metric == "average") {
        E(graph)$w <- vapply(X = E(graph)$weight, FUN.VALUE = numeric(1),
                             FUN = function(x) {return(sum(x)/2)})
    }
    if(metric == "strict") {
        E(graph)$w <- vapply(X = E(graph)$weight, FUN.VALUE = numeric(1),
                             FUN = function(x) {
                                 if(length(x)==2) {
                                     return(min(x))
                                 }
                                 return(min(x,0))})
    }
    if(metric == "loose") {
        E(graph)$w <- vapply(X = E(graph)$weight, FUN.VALUE = numeric(1),
                             FUN = function(x) {
                                 if(length(x)==2) {
                                     return(max(x))
                                 }
                                 return(max(x,0))})
    }
    
    graph <- delete_edges(graph = graph, which(E(graph)$w <= 0))
    # if trim*2 > CDR3 lengths -> NA
    graph <- delete_edges(graph = graph, which(is.na(E(graph)$w)))
    return(graph)
}

get_community_detection <- function(g, 
                                    algorithm, 
                                    resolution) {
    
    if(algorithm == "louvain") {
        c <- cluster_louvain(graph = g, 
                             weights = E(g)$w, 
                             resolution = resolution)
        V(g)$community <- c$membership
    }
    if(algorithm == "leiden") {
        c <- cluster_leiden(graph = g, 
                            weights = E(g)$w, 
                            resolution = resolution,
                            n_iterations = 100)
        V(g)$community <- c$membership
    }
    return(g)
}

get_community_summary <- function(g, 
                                  chains, 
                                  metric) {
    
    get_vstats <- function(vs, wide) {
        
        vs$cells <- vs$clone_size
        vs$clones <- 1
        
        if(wide) {
            # number of cells
            vcells <- aggregate(cells~community+sample, data = vs, FUN = sum)
            vcells <- acast(data = vcells, formula = community~sample, 
                            value.var = "cells", fill = 0)
            vcells <- data.frame(vcells)
            vcells$n <- apply(X = vcells, MARGIN = 1, FUN = sum)
            colnames(vcells) <- paste0("cells_", colnames(vcells))
            vcells$community <- rownames(vcells)
            vcells$community <- as.numeric(as.character(vcells$community))
            vcells <- vcells[order(vcells$community, decreasing = FALSE), ]
            
            # number of clones
            vclones <- aggregate(clones~community+sample, data = vs, FUN = sum)
            vclones <- acast(data = vclones, formula = community~sample, 
                             value.var = "clones", fill = 0)
            vclones <- data.frame(vclones)
            vclones$n <- apply(X = vclones, MARGIN = 1, FUN = sum)
            colnames(vclones) <- paste0("clones_", colnames(vclones))
            vclones$community <- rownames(vclones)
            vclones$community <- as.numeric(as.character(vclones$community))
            vclones <- vclones[order(vclones$community, decreasing = FALSE), ]
            
            # merge clones and cells
            vstats <- merge(x = vclones, y = vcells, by = "community")
        } 
        else {
            # number of cells
            vcells <- aggregate(cells~community+sample, data = vs, 
                                FUN = sum, drop = FALSE)
            
            # number of clones
            vclones <- aggregate(clones~community+sample, data = vs, 
                                 FUN = sum, drop = FALSE)
            
            # merge clones and cells
            vstats <- merge(x = vclones, y = vcells, 
                            by = c("community", "sample"))
            vstats$cells[is.na(vstats$cells)] <- 0
            vstats$clones[is.na(vstats$clones)] <- 0
        }
        
        return(vstats)
    }
    
    get_estats <- function(x, g, chains) {
        sg <- subgraph(graph = g, vids = which(V(g)$community==x))
        
        if(length(sg)==1) {
            v <- numeric(length = length(chains)*2+1)
            names(v) <- c("w", paste0("w_", chains), paste0("n_", chains))
            v <- c(x, v)
            names(v)[1] <- "community"
            return(v)
        }
        
        es <- as_data_frame(x = sg, what = "edges")
        l <- lapply(X = 1:nrow(es), es = es, chains, 
                    FUN = function(x, es, chains) {
                        v <- numeric(length = length(chains)*2+1)
                        names(v) <- c("w", paste0("w_", chains), 
                                      paste0("n_", chains))
                        for(c in chains) {
                            i <- which(es$chain[[x]]==c)
                            if(length(i)==0) {
                                v[paste0("w_", c)] <- 0
                                v[paste0("n_", c)] <- 0
                            } else {
                                v["w"] <- es$w[[x]][i]
                                v[paste0("w_", c)] <- es$weight[[x]][i]
                                v[paste0("n_", c)] <- 1
                            }
                        }
                        return(v)
                    })
        l <- data.frame(do.call(rbind, l))
        l <- c(x, colMeans(l[,which(regexpr(pattern = "w", 
                                            text = colnames(l))!=-1)]),
               colSums(l[,which(regexpr(pattern = "n", 
                                        text = colnames(l))!=-1), drop=FALSE]))
        
        names(l)[1] <- "community"
        return(l)
    } 
    
    # get community statistics on edges
    es <- lapply(X = unique(V(g)$community), g = g, 
                 chains = chains, FUN = get_estats)
    es <- data.frame(do.call(rbind, es))
    
    # get community statistics on vertices (wide and tall format)
    vs_wide <- get_vstats(vs = as_data_frame(x = g, what = "vertices"), 
                          wide = TRUE)
    vs_tall <- get_vstats(vs = as_data_frame(x = g, what = "vertices"), 
                          wide = FALSE)
    
    # merge results
    cs_wide <- merge(x = vs_wide, y = es, by = "community", all.x = TRUE)
    cs_wide <- cs_wide[order(cs_wide$community, decreasing = FALSE), ]
    
    cs_tall <- merge(x = vs_tall, y = es, by = "community", all.x = TRUE)
    cs_tall <- cs_tall[order(vs_tall$community, decreasing = FALSE), ]
    
    
    return(list(wide = cs_wide, 
                tall = cs_tall))
}

get_community_matrix <- function(g) {
    vs <- as_data_frame(x = g, what = "vertices")
    
    cm <- acast(data = vs, formula = community~sample, 
                value.var = "clone_size", 
                fun.aggregate = sum, fill = 0)
    
    return(cm)
}

check_inputs <- function(graph, 
                         algorithm, 
                         resolution,
                         weight, 
                         metric, 
                         chains) {
    
    
    # check graph
    if(missing(graph)) {
        stop("graph must be an igraph object")
    }
    if(is_igraph(graph)==FALSE) {
        stop("graph must be an igraph object")
    }
    
    # check algorithm
    if(missing(algorithm)) {
        stop("algorithm must be louvain or leiden")
    }
    if(length(algorithm)!=1) {
        stop("algorithm must be louvain or leiden")
    }
    if(is.character(algorithm)==FALSE) {
        stop("algorithm must be character")
    }
    if(!algorithm %in% c("louvain", "leiden")) {
        stop("algorithm must be louvain or leiden")
    }
    
    
    # check resolution
    if(missing(resolution)) {
        stop("resolution must be a number > 0")
    }
    if(length(resolution)!=1) {
        stop("resolution must be a number > 0")
    }
    if(is.numeric(resolution)==FALSE) {
        stop("resolution must be a number > 0")
    }
    if(is.finite(resolution)==FALSE) {
        stop("resolution must be a number > 0")
    }
    if(resolution<=0) {
        stop("resolution must be a number > 0")
    }
    
    
    # check weight
    if(missing(weight)) {
        stop("weight must be ncweight or nweight")
    }
    if(length(weight)!=1) {
        stop("weight must be ncweight or nweight")
    }
    if(is.character(weight)==FALSE) {
        stop("weight must be character")
    }
    if(!weight %in% c("ncweight", "nweight")) {
        stop("weight must be ncweight or nweight")
    }
    
    
    
    # check metric
    if(missing(metric)) {
        stop("metric must be average, strict or loose")
    }
    if(length(metric)!=1) {
        stop("metric must be average, strict or loose")
    }
    if(is.character(metric)==FALSE) {
        stop("metric must be character")
    }
    if(!metric %in% c("average", "strict", "loose")) {
        stop("metric must be average, strict or loose")
    }
    
    
    
    # check chains
    if(missing(chains)) {
        stop("chains must be a character vector")
    }
    if(length(chains)<1 | length(chains)>2) {
        stop("chains must be a character vector")
    }
    if(is.character(chains)==FALSE) {
        stop("chains must be a character vector")
    }
    if(any(chains %in% c("CDR3a", "CDR3b", "CDR3g", 
                         "CDR3d", "CDR3h", "CDR3l"))==FALSE) {
        stop("chains must be a character vector")
    }
    
}
