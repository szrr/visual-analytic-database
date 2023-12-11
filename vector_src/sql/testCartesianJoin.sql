select video_name, DISTANCE(s_feature, d_feature)
from search_video, dataset_video
;