select frame_id, OUTLIER_SCORE(sum_dis)
from(
    select frame_id, object_id, SUM(DISTANCE(test_feature, train_feature)) as sum_dis
    from test_video kNN(k=10) join train_video on test_feature=train_feature
    group by frame_id, object_id) test_objects
where sum_dis > (
    select OUTLIER_LINE(train_feature)
    from train_video)
group by frame_id

;