select frame_id, OUTLIER_SCORE(
    select kNN_AVG_DISTANCE(test_feature, train_feature)
    from train_video)
from (
    select frame_id, test_feature
    from test_video
    where 
    (
        select kNN_AVG_DISTANCE(test_feature, train_feature)
        from train_video) > 
    (   
        select OUTLIER_LINE(train_feature)
        from train_video)
    )
group by frame_id
;