select video_name, VIDEO_SIMILARITY(DISTANCE(s_feature, d_feature)) as distance
from search_video, dataset_video
where video_name in (
    select video_name
    from search_video kNN(k=5) join dataset_video on s_feature=d_feature
)
group by video_name
order by distance

;
