select video_name, VIDEO_SIMILARITY(DISTANCE(s_feature, d_feature)) as score
from search_video, (
    select video_name, d_feature
    from dataset_video
    where video_name in (
        select video_name
        from search_video kNN(k=5) join dataset_video on s_feature = d_feature)
    ) candidate_dataset
group by video_name
order by score

;