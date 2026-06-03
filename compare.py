import mosspy

userid = 112623940

m = mosspy.Moss(userid, "verilog")

m.addBaseFile("OT/GE_dbg.sv")

# Submission Files
m.addFile("OT/GE.sv")
m.addFile("OT/GE_Neko.sv")
#m.addFilesByWildcard("submission/a01-*.sv")

url = m.send() # Submission Report URL

print ("Report Url: " + url)

# Save report file
m.saveWebPage(url, "OT/compare_report.html")

# Download whole report locally including code diff links
mosspy.download_report(url, "OT/report/", connections=8)