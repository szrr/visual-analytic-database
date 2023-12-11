select video_name, video_similarity(distance(s_feature, d_feature)) as score
from search, dataset
where distance(s_feature, d_feature) < 0.5
group by video_name
;