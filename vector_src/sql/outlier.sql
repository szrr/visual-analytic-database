select frame_id, OUTLIER_SCORE(kNN_AVG_DISTANCE(test_feature, train_feature))
from test_video, train_video
where kNN_AVG_DISTANCE(test_feature, train_feature) > (
    select OUTLIER_LINE(train_feature)
    from train_video)
group by frame_id
;
