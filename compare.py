import mosspy

userid = 112623940

m = mosspy.Moss(userid, "verilog")

m.addBaseFile("DCS_FINAL/CA_TA.sv")

# Submission Files
m.addFile("DCS_FINAL/CA.sv")
m.addFile("DCS_FINAL/CA_Neko.sv")
#m.addFilesByWildcard("submission/a01-*.sv")

url = m.send() # Submission Report URL

print ("Report Url: " + url)

# Save report file
m.saveWebPage(url, "DCS_FINAL/compare_report.html")

# Download whole report locally including code diff links
mosspy.download_report(url, "DCS_FINAL/report/", connections=8)