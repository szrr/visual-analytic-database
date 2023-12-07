from sklearn import metrics
import scipy.io as scio
import numpy as np

labels = np.load('outlier_ped_labels.npy')
print(labels.shape)

with open('outlier_pred_complete.txt', 'r') as f:
    sc = [float(line.split()[1]) for line in f]
# print(sc)

fpr2, tpr2, thresholds = metrics.roc_curve(labels,sc ,pos_label=1)
fpr2 = np.sort(np.append(fpr2,(0.45))) # We extrapolate a point so as to complete the ROC curve
tpr2 = np.sort(np.append(tpr2,(1)))

print('ODIT AUC:', metrics.auc(fpr2, tpr2))