import mosspy

userid = 112623940

m = mosspy.Moss(userid, "python")

m.addBaseFile("submission/a01.py")
m.addBaseFile("submission/test_student.py")

# Submission Files
m.addFile("submission/a01-sample.py")
m.addFilesByWildcard("submission/a01-*.py")

url = m.send() # Submission Report URL

print ("Report Url: " + url)

# Save report file
m.saveWebPage(url, "submission/report.html")

# Download whole report locally including code diff links
mosspy.download_report(url, "submission/report/", connections=8)