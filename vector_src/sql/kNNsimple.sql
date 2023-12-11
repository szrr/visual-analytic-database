select video_name, d_feature
from dataset
where video_name in (
    select video_name
    from search kNN(k=5) join dataset on s_feature = d_feature)
;