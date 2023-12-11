select video_name, distance(s_feature, d_feature) as dis
from search, dataset
where distance(s_feature, d_feature) < 0.5
order by dis
;