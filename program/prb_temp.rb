
Flow.create do

  log 'import statement'
  import 'components/temp' 

  log 'direct call'
  
  meas :bgap_voltage_meas, tnum: 1050, bin: 119, soft_bin: 2, hi_limit: 45
  meas :bgap_voltage_meas1

end

